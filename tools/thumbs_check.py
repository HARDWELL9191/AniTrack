# Why are episode thumbnails/descriptions empty? Checks the raw data and whether images load.
import json, time, urllib.request
def head(url):
    try:
        req = urllib.request.Request(url, method="GET", headers={"User-Agent": UA, "Range": "bytes=0-64"})
        with urllib.request.urlopen(req, timeout=15) as r: return r.status
    except urllib.error.HTTPError as e: return e.code
    except Exception as e: return str(e)[:60]
lines = []
for search in ["Kono Subarashii Sekai ni Shukufuku wo! 2", "Noble Reincarnation", "Mushoku Tensei", "Tensei shitara Slime Datta Ken 2nd Season", "Overgeared"]:
    time.sleep(2)
    st, raw, _ = run("query($s:String){ Media(search:$s, type: ANIME){ id idMal title { romaji } episodes streamingEpisodes { title thumbnail site } } }", {"s": search})
    m = (json.loads(raw).get("data") or {}).get("Media") or {}
    se = m.get("streamingEpisodes") or []
    hosts = sorted(set((e.get("thumbnail") or "").split("/")[2] for e in se if e.get("thumbnail")))
    t0 = next((e.get("thumbnail") for e in se if e.get("thumbnail")), None)
    line = f"{m.get('title',{}).get('romaji','?')[:34]} (id {m.get('id')}, eps {m.get('episodes')}): anilist streaming={len(se)} hosts={hosts} first thumb HTTP={head(t0) if t0 else '-'}"
    # Kitsu
    st, d, dt, _ = kget(f"{base}/mappings?filter%5BexternalSite%5D=anilist/anime&filter%5BexternalId%5D={m.get('id')}&include=item")
    inc = [x for x in d.get("included", []) if x.get("type") == "anime"]
    if inc:
        kid = inc[0]["id"]
        st, d, dt, _ = kget(f"{base}/anime/{kid}/episodes?page%5Blimit%5D=20&sort=number&fields%5Bepisodes%5D=number,canonicalTitle,description,synopsis,thumbnail")
        data = d.get("data", [])
        desc = sum(1 for e in data if (e["attributes"].get("description") or e["attributes"].get("synopsis")))
        th = [((e["attributes"].get("thumbnail") or {}).get("original")) for e in data]
        th = [x for x in th if x]
        line += f" | kitsu {kid}: eps={len(data)} desc={desc} thumbs={len(th)} first thumb HTTP={head(th[0]) if th else '-'}"
        if th: line += f" ({th[0][:70]})"
    else:
        line += " | kitsu: no mapping"
    if t0: line += f"\n   anilist thumb sample: {t0[:90]}"
    lines.append(line)
note("thumbs check", "\n".join(lines))
