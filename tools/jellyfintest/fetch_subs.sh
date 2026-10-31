#!/bin/bash
# Real Jellyfin server: library with a zlib-compressed PGS MKV; fetch its subtitle the way
# JellyReco does (Videos/{id}/{source}/Subtitles/{index}/0/Stream.pgssub) and check it.
set -uo pipefail
media="$1"; out="$2"; mkdir -p "$out"
J=http://localhost:8096
H='MediaBrowser Client="ci", Device="ci", DeviceId="ci-1", Version="1.0"'
for i in $(seq 1 90); do curl -fs $J/System/Info/Public >/dev/null && break; sleep 2; done
curl -fs $J/System/Info/Public | tee "$out/server.json"; echo
curl -fs -X POST $J/Startup/Configuration -H "Content-Type: application/json" -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'
curl -fs $J/Startup/User >/dev/null
curl -fs -X POST $J/Startup/User -H "Content-Type: application/json" -d '{"Name":"ci","Password":"ci"}'
curl -fs -X POST $J/Startup/Complete
TOKEN=$(curl -fs -X POST $J/Users/AuthenticateByName -H "Authorization: $H" -H "Content-Type: application/json" -d '{"Username":"ci","Pw":"ci"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['AccessToken'])")
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
