# Why do some shows have no age rating? Checks Tim's whole list + this season's popular shows.
import json, time
def kget2(url):
    return kget(url)
q = """query($id:Int){ MediaListCollection(userId:$id, type: ANIME){ lists { isCustomList entries { media { id idMal format status seasonYear title { english romaji } } } } } }"""
me = json.loads(run(query("userByName"), {"name": "HARDWELL9191"})[1])["data"]["User"]
coll = json.loads(run(q, {"id": me["id"]})[1])["data"]["MediaListCollection"]
shows = {}
for l in coll["lists"]:
    for e in l["entries"]: shows[e["media"]["id"]] = e["media"]
time.sleep(1)
sq = """query{ Page(perPage: 50){ media(type: ANIME, season: FALL, seasonYear: 2026, sort: POPULARITY_DESC, isAdult: false){ id idMal format status seasonYear title { english romaji } } } }"""
for m in json.loads(run(sq, {})[1])["data"]["Page"]["media"]: shows[m["id"]] = m
ids = list(shows)
found_map, rated = {}, {}
for i in range(0, len(ids), 20):
    chunk = ids[i:i+20]
    st, d, dt, _ = kget(f"{base}/mappings?filter%5BexternalSite%5D=anilist/anime&filter%5BexternalId%5D={','.join(map(str,chunk))}&include=item&page%5Blimit%5D=20&fields%5Banime%5D=ageRating,ageRatingGuide")
    inc = {x["id"]: x["attributes"] for x in d.get("included", []) if x.get("type") == "anime"}
    rows = d.get("data", [])
    for r in rows:
        ext = int(r["attributes"]["externalId"]); kid = r["relationships"]["item"]["data"]["id"]
        found_map.setdefault(ext, kid); a = inc.get(kid, {})
        if a.get("ageRating"): rated[ext] = a["ageRating"]
    if len(rows) >= 20: note("kitsu page full", f"chunk {i}: {len(rows)} rows (some shows may be cut off!)", "warning")
    time.sleep(0.4)
no_map = [shows[i] for i in ids if i not in found_map]
no_rating = [shows[i] for i in ids if i in found_map and i not in rated]
# MAL fallback for unmapped
mal_found = []
for m in no_map[:40]:
    if not m.get("idMal"): continue
    st, d, dt, _ = kget(f"{base}/mappings?filter%5BexternalSite%5D=myanimelist/anime&filter%5BexternalId%5D={m['idMal']}&include=item&fields%5Banime%5D=ageRating,ageRatingGuide")
    inc = [x for x in d.get("included", []) if x.get("type") == "anime"]
    if inc: mal_found.append(f"{(m['title']['english'] or m['title']['romaji'])[:40]} -> {inc[0]['attributes'].get('ageRating')}")
    time.sleep(0.4)
t = lambda m: f"{(m['title']['english'] or m['title']['romaji'])[:40]} [{m['format']}, {m['status']}, {m.get('seasonYear')}]"
note("kitsu missing summary", f"shows checked={len(ids)}; mapped via AniList id={len(found_map)}; with rating={len(rated)}; no mapping={len(no_map)}; mapped but no rating={len(no_rating)}; MAL fallback found={len(mal_found)}")
note("kitsu no mapping", "\n".join(t(m) for m in no_map[:30]))
note("kitsu no rating", "\n".join(t(m) for m in no_rating[:30]))
note("kitsu MAL fallback", "\n".join(mal_found[:30]) or "none")
