#!/bin/bash
# Real Jellyfin server: library with a zlib-compressed PGS MKV; fetch its subtitle the way
# JellyReco does (Videos/{id}/{source}/Subtitles/{index}/0/Stream.pgssub) and check it.
set -uo pipefail
media="$1"; out="$2"; mkdir -p "$out"
J=http://localhost:8096
H='MediaBrowser Client="ci", Device="ci", DeviceId="ci-1", Version="1.0"'
req() { # method url [json] -> prints "HTTP code" and body on failure, body to stdout file
  local m="$1" u="$2" d="${3:-}" code
  if [ -n "$d" ]; then code=$(curl -s -o /tmp/resp -w "%{http_code}" -X "$m" "$u" -H "Authorization: $H" -H "Content-Type: application/json" -d "$d")
  else code=$(curl -s -o /tmp/resp -w "%{http_code}" -X "$m" "$u" -H "Authorization: $H"); fi
  echo "  $m ${u#$J} -> $code" >&2
  [ "${code:0:1}" = "2" ] || { head -c 400 /tmp/resp >&2; echo >&2; }
  cat /tmp/resp
}
# The server answers /System/Info/Public before the setup wizard is ready: wait for the wizard.
for i in $(seq 1 120); do
  c=$(curl -s -o /dev/null -w "%{http_code}" $J/Startup/Configuration -H "Authorization: $H")
  [ "$c" = "200" ] && break; sleep 2
done
echo "wizard ready (HTTP $c)"
curl -s $J/System/Info/Public | tee "$out/server.json"; echo
req POST $J/Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
req GET $J/Startup/User >/dev/null
req POST $J/Startup/User '{"Name":"ci","Password":"ci"}' >/dev/null
req POST $J/Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
req POST $J/Startup/Complete >/dev/null
for i in $(seq 1 30); do
  TOKEN=$(req POST $J/Users/AuthenticateByName '{"Username":"ci","Pw":"ci"}' | python3 -c "import json,sys
try: print(json.load(sys.stdin)['AccessToken'])
except Exception: print('')")
  [ -n "$TOKEN" ] && break; sleep 2
done
A="Authorization: $H, Token=\"$TOKEN\""
echo "token ok: ${#TOKEN} chars"
curl -fs -X POST "$J/Library/VirtualFolders?name=Test&collectionType=movies&paths=/media&refreshLibrary=true" -H "$A" -H "Content-Type: application/json" -d '{"LibraryOptions":{}}'
UID_=$(curl -fs $J/Users -H "$A" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['Id'])")
for i in $(seq 1 60); do
  ITEMS=$(curl -fs "$J/Items?userId=$UID_&recursive=true&includeItemTypes=Movie&fields=MediaSources,MediaStreams" -H "$A")
  echo "$ITEMS" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin)['Items'] else 1)" && break
  sleep 3
done
echo "$ITEMS" > "$out/items.json"
echo "$ITEMS" | python3 -c "
import json,sys
for it in json.load(sys.stdin)['Items']:
  for s in it['MediaSources'][0]['MediaStreams']:
    print(it['Name'], it['Id'], it['MediaSources'][0]['Id'], s['Index'], s['Type'], s.get('Codec'), s.get('IsExternal'))" | tee "$out/streams.txt"
grep -i "Subtitle" "$out/streams.txt" | while read name id src idx type codec ext; do
  for fmt in pgssub sup; do
    code=$(curl -s -o "$out/$name.$idx.$fmt" -w "%{http_code}" "$J/Videos/$id/$src/Subtitles/$idx/0/Stream.$fmt?ApiKey=$TOKEN")
    size=$(stat -c %s "$out/$name.$idx.$fmt" 2>/dev/null || echo 0)
    magic=$(head -c 2 "$out/$name.$idx.$fmt" 2>/dev/null)
    echo "FETCH $name sub#$idx as .$fmt -> HTTP $code, $size bytes, starts with '$magic'"
  done
done
