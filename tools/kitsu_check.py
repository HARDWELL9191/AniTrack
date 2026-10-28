# Kitsu probe (run through tools/api_check.py with username "kitsu").
# Uses note()/run()/query() from api_check.py.
import json, time, urllib.request, urllib.error, urllib.parse

def kget(url):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.api+json", "User-Agent": UA})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}"), time.time() - t, r.geturl()
    except urllib.error.HTTPError as e:
        try: body = json.loads(e.read() or b"{}")
        except Exception: body = {}
        return e.code, body, time.time() - t, url
    except Exception as e:
        return 0, {"error": str(e)}, time.time() - t, url

lines = []
base = None
for b in ["https://kitsu.app/api/edge", "https://kitsu.io/api/edge"]:
    st, d, dt, final = kget(b + "/anime?page[limit]=1")
    lines.append(f"base {b}: HTTP {st} in {dt:.1f}s final={final}")
    if st == 200 and base is None: base = b
note("kitsu base", "\n".join(lines))
if not base: raise SystemExit(0)

# Shows: Tim's list (mix of statuses) + a few new/old ones.
me = json.loads(run(query("userByName"), {"name": "HARDWELL9191"})[1])["data"]["User"]
coll = json.loads(run(query("listCollection"), {"userId": me["id"]})[1])["data"]["MediaListCollection"]
mine = []
for l in coll["lists"]:
    if l.get("isCustomList"): continue
    for e in l["entries"]: mine.append(e["media"])
extra_ids = [178754, 182255, 21, 11617, 1535, 20, 199112]  # Kaiju No.8 S2, Frieren-ish/new, One Piece, DxD, Death Note, Naruto, recent
picked = mine[:14]
time.sleep(1)
st, raw, _ = run(query("mediaByIds"), {"ids": extra_ids, "perPage": len(extra_ids)})
picked += (json.loads(raw).get("data") or {}).get("Page", {}).get("media", []) or []

FIELDS = "fields[anime]=canonicalTitle,ageRating,ageRatingGuide,episodeCount,subtype"
ratings, misses, kitsu_ids = [], [], {}
for m in picked:
    url = f"{base}/mappings?filter[externalSite]=anilist/anime&filter[externalId]={m['id']}&include=item&{FIELDS}"
    st, d, dt, _ = kget(url)
    inc = [x for x in d.get("included", []) if x.get("type") == "anime"]
    title = m["title"].get("english") or m["title"].get("romaji")
    if inc:
        a = inc[0]["attributes"]; kitsu_ids[m["id"]] = inc[0]["id"]
        ratings.append(f"{title[:38]} -> {a.get('ageRating')} | {a.get('ageRatingGuide')} | eps {a.get('episodeCount')} ({dt:.1f}s)")
    else:
        # fallback: MyAnimeList id mapping
        mal = m.get("idMal")
        st2, d2, dt2, _ = kget(f"{base}/mappings?filter[externalSite]=myanimelist/anime&filter[externalId]={mal}&include=item&{FIELDS}") if mal else (0, {}, 0, "")
        inc2 = [x for x in d2.get("included", []) if x.get("type") == "anime"]
        if inc2:
            a = inc2[0]["attributes"]; kitsu_ids[m["id"]] = inc2[0]["id"]
            ratings.append(f"{title[:38]} -> (via MAL) {a.get('ageRating')} | {a.get('ageRatingGuide')}")
        else:
            misses.append(f"{title[:38]} (anilist HTTP {st}, mal {mal})")
    time.sleep(0.4)
note("kitsu ratings", f"found {len(ratings)}/{len(picked)}\n" + "\n".join(ratings) + "\nMISSES: " + "; ".join(misses))

# Batch lookup: several AniList ids in one request?
ids = ",".join(str(m["id"]) for m in picked[:10])
st, d, dt, _ = kget(f"{base}/mappings?filter[externalSite]=anilist/anime&filter[externalId]={ids}&include=item&page[limit]=20&{FIELDS}")
note("kitsu batch", f"10 ids in one request: HTTP {st} in {dt:.1f}s, mappings returned={len(d.get('data', []))}, anime included={len([x for x in d.get('included', []) if x.get('type')=='anime'])}, errors={str(d.get('errors'))[:300]}")
kids = ",".join(list(kitsu_ids.values())[:10])
st, d, dt, _ = kget(f"{base}/anime?filter[id]={kids}&page[limit]=20&{FIELDS}")
note("kitsu batch by kitsu id", f"HTTP {st} in {dt:.1f}s returned={len(d.get('data', []))} errors={str(d.get('errors'))[:200]}")

# Episodes: Kitsu descriptions/thumbnails vs AniList streamingEpisodes.
eps_lines = []
for m in picked[:12]:
    kid = kitsu_ids.get(m["id"])
    title = (m["title"].get("english") or m["title"].get("romaji"))[:34]
    k_info = "no kitsu id"
    if kid:
        st, d, dt, _ = kget(f"{base}/anime/{kid}/episodes?page[limit]=20&sort=number&fields[episodes]=number,seasonNumber,canonicalTitle,synopsis,description,thumbnail")
        data = d.get("data", [])
        withdesc = sum(1 for e in data if (e["attributes"].get("description") or e["attributes"].get("synopsis")))
        withthumb = sum(1 for e in data if (e["attributes"].get("thumbnail") or {}).get("original"))
        withtitle = sum(1 for e in data if e["attributes"].get("canonicalTitle"))
        total = (d.get("meta") or {}).get("count")
        k_info = f"kitsu eps={total} firstpage={len(data)} desc={withdesc} thumb={withthumb} title={withtitle} ({dt:.1f}s)"
        time.sleep(0.4)
    st, raw, _ = run("query($id:Int){ Media(id:$id){ episodes streamingEpisodes { title thumbnail site } } }", {"id": m["id"]})
    md = (json.loads(raw).get("data") or {}).get("Media") or {}
    se = md.get("streamingEpisodes") or []
    eps_lines.append(f"{title}: anilist eps={md.get('episodes')} streaming={len(se)} ({','.join(sorted(set(s.get('site') or '' for s in se)))}) | {k_info}")
    time.sleep(1.2)
note("kitsu episodes", "\n".join(eps_lines))

# One sample episode, to see the shape.
if kitsu_ids:
    kid = list(kitsu_ids.values())[0]
    st, d, dt, _ = kget(f"{base}/anime/{kid}/episodes?page[limit]=1&sort=number")
    if d.get("data"):
        a = d["data"][0]["attributes"]
        note("kitsu episode sample", json.dumps({k: a.get(k) for k in ["number","seasonNumber","canonicalTitle","titles","synopsis","description","airdate","length","thumbnail"]})[:2500])
