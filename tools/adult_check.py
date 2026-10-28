# Checks the Hentai category exactly as the app requests it (username "adult").
import json, time
lines = []
st, raw, _ = run(query("categories"), {})
genres = (json.loads(raw).get("data") or {}).get("GenreCollection") or []
lines.append(f"categories HTTP {st}: Hentai in GenreCollection = {'Hentai' in genres}")
for adult in (True, False):
    time.sleep(2)
    v = {"page": 1, "perPage": 30, "sort": ["POPULARITY_DESC"], "isAdult": adult, "genres": ["Hentai"]}
    st, raw, _ = run(query("browse"), v)
    d = json.loads(raw)
    media = ((d.get("data") or {}).get("Page") or {}).get("media") or []
    info = ((d.get("data") or {}).get("Page") or {}).get("pageInfo")
    lines.append(f"browse genre Hentai isAdult={adult}: HTTP {st}, {len(media)} shows, pageInfo {info}, "
                 f"all adult={all(m.get('isAdult') for m in media) if media else None}, errors {d.get('errors')}")
    if adult and media:
        first = media[0]["id"]
time.sleep(2)
st, raw, _ = run(query("browseWithRelations"), {"page": 1, "perPage": 40, "sort": ["SCORE_DESC"], "isAdult": True,
                                               "genres": ["Hentai"], "excludeIds": [1]})
d = json.loads(raw)
lines.append(f"recommender exploration (browseWithRelations, isAdult true): HTTP {st}, "
             f"{len(((d.get('data') or {}).get('Page') or {}).get('media') or [])} shows, errors {d.get('errors')}")
time.sleep(2)
st, raw, _ = run(query("detail"), {"id": first})
d = json.loads(raw)
m = (d.get("data") or {}).get("Media") or {}
lines.append(f"detail of adult show {first}: HTTP {st}, title {((m.get('title') or {}).get('romaji'))}, isAdult {m.get('isAdult')}, errors {d.get('errors')}")
time.sleep(2)
st, raw, _ = run(query("browse"), {"page": 1, "perPage": 50, "sort": ["POPULARITY_DESC"], "isAdult": False})
media = ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media") or []
lines.append(f"normal browse isAdult=false: {len(media)} shows, any adult = {any(m.get('isAdult') for m in media)}")
note("adult check", "\n".join(lines))
