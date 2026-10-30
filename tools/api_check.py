"""Runs the app's GraphQL queries (read from AniListClient.swift) against AniList
and reports results as GitHub annotations, so they can be read through the API."""
import json
import os
import re
import time
import urllib.error
import urllib.request

SRC = open("AniReco/Services/AniListClient.swift").read()
blocks = dict(re.findall(r'static let (\w+) = """\n(.*?)\n\s*"""', SRC, re.S))
fragment = blocks["mediaFragment"]
relfrag = blocks.get("relFragment", "")


def query(name):
    after = SRC.split(f"static let {name} = ")[1].split("static let")[0]
    return (blocks[name] + ("\n" + fragment if "+ mediaFragment" in after else "")
            + ("\n" + relfrag if "+ relFragment" in after else ""))


def note(title, msg, level="notice"):
    if os.environ.get("ANILIST_USER", "") == "twins" and not title.startswith("twins"):
        return
    if os.environ.get("ANILIST_USER", "") == "seasons" and not title.startswith(("season", "browseWithRelations", "seedRecommendations", "mediaByIds")):
        return
    msg = str(msg).replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::{level} title={title}::{msg[:3500]}", flush=True)


UA = os.environ.get("TEST_UA", "AniReco/1 CFNetwork/3860.100.1 Darwin/27.0.0")


def run(q, variables):
    body = json.dumps({"query": q, "variables": variables}).encode()
    req = urllib.request.Request("https://graphql.anilist.co", data=body,
                                 headers={"Content-Type": "application/json", "Accept": "application/json",
                                          "User-Agent": UA})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, raw, time.time() - t
    except urllib.error.HTTPError as e:
        return e.code, e.read(), time.time() - t


if os.environ.get("ANILIST_USER", "") == "thumbs":
    import traceback
    try:
        _src = open("tools/kitsu_check.py").read()
        exec(_src.split("# Shows: Tim's list")[0], globals())
        exec(open("tools/thumbs_check.py").read(), globals())
    except SystemExit:
        pass
    except Exception:
        note("thumbs crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "fastload":
    import traceback
    try:
        exec(open("tools/fastload_check.py").read(), globals())
    except Exception:
        note("fastload crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "konosuba":
    import traceback
    try:
        exec(open("tools/konosuba_check.py").read(), globals())
    except Exception:
        note("konosuba crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "listcheck":
    import traceback
    try:
        exec(open("tools/list_check.py").read(), globals())
    except Exception:
        note("listcheck crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "branches":
    import traceback
    try:
        exec(open("tools/branch_check.py").read(), globals())
    except Exception:
        note("branches crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "seasons2":
    import traceback
    try:
        exec(open("tools/seasons2_check.py").read(), globals())
    except Exception:
        note("seasons2 crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "movies":
    import traceback
    try:
        exec(open("tools/movies_check.py").read(), globals())
    except Exception:
        note("movies crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "adult":
    import traceback
    try:
        exec(open("tools/adult_check.py").read(), globals())
    except Exception:
        note("adult crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "align":
    import traceback
    try:
        exec(open("tools/align_check.py").read(), globals())
    except Exception:
        note("align crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "episodes":
    import traceback
    try:
        exec(open("tools/episodes_check.py").read(), globals())
    except Exception:
        note("episodes crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "kitsu-missing":
    import traceback
    try:
        _src = open("tools/kitsu_check.py").read()
        exec(_src.split("# Shows: Tim's list")[0], globals())   # helpers + base
        exec(open("tools/kitsu_missing.py").read(), globals())
    except SystemExit:
        pass
    except Exception:
        note("kitsu crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "kitsu":
    import traceback
    try:
        exec(open("tools/kitsu_check.py").read(), globals())
    except SystemExit:
        pass
    except Exception:
        note("kitsu crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

if os.environ.get("ANILIST_USER", "") == "twins":
    # Only the taste-twins check (keeps AniList's rate limit for it).
    import traceback
    try:
        code = open(__file__).read().split("# Taste twins (collaborative filtering): mirrors")[-1].split("\n", 1)[1]
        exec(code, globals())
    except SystemExit:
        pass
    except Exception:
        note("twins crash", traceback.format_exc()[-1500:], "error")
    raise SystemExit(0)

SEASONS_ONLY = os.environ.get("ANILIST_USER", "") == "seasons"   # GitHub shows max 10 notices per step

# Raw probe: show exactly what AniList answers, headers included.
for ua in ([] if SEASONS_ONLY else ["Python-urllib/3.12", UA]):
    body = json.dumps({"query": "query { Media(id: 1) { id } }"}).encode()
    req = urllib.request.Request("https://graphql.anilist.co", data=body,
                                 headers={"Content-Type": "application/json", "Accept": "application/json", "User-Agent": ua})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            note("probe " + ua, f"HTTP {r.status} {r.read()[:300]!r}")
    except urllib.error.HTTPError as e:
        hdrs = {k: v for k, v in e.headers.items() if k.lower() in ("server", "cf-ray", "content-type", "retry-after", "x-ratelimit-remaining")}
        note("probe " + ua, f"HTTP {e.code} headers={hdrs} body={e.read()[:600]!r}", "warning")

def check_user(uid, label):
    status, raw, dt = run(query("listCollection"), {"userId": uid})
    try:
        data = json.loads(raw)
    except Exception:
        note("listCollection " + label, f"HTTP {status} non-JSON body={raw[:500]!r}", "error")
        return
    lists = (((data.get("data") or {}).get("MediaListCollection") or {}).get("lists")) or []
    summary = [(l.get("name"), l.get("status"), l.get("isCustomList"), len(l.get("entries") or [])) for l in lists]
    note("listCollection " + label,
         f"HTTP {status} in {dt:.1f}s, {len(raw)//1024} KB, errors={data.get('errors')}, lists={summary}",
         "notice" if status == 200 and not data.get("errors") else "error")
    problems = []
    for l in lists:
        if l.get("status") is not None and l.get("status") not in {"CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED", "REPEATING"}:
            problems.append(f"list status={l.get('status')}")
        for e in l.get("entries") or []:
            m = e.get("media") or {}
            if e.get("status") not in {"CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED", "REPEATING"}:
                problems.append(f"entry {e.get('id')} status={e.get('status')}")
            for k in ("id", "mediaId"):
                if not isinstance(e.get(k), int):
                    problems.append(f"entry {e.get('id')} {k}={e.get(k)!r}")
            if e.get("score") is not None and not isinstance(e.get("score"), (int, float)):
                problems.append(f"entry {e.get('id')} score={e.get('score')!r}")
            if not isinstance(m.get("id"), int) or not isinstance(m.get("title"), dict):
                problems.append(f"entry {e.get('id')} media id/title={m.get('id')!r}")
            for t in m.get("tags") or []:
                if not isinstance(t.get("name"), str):
                    problems.append(f"media {m.get('id')} tag name={t.get('name')!r}")
            na = m.get("nextAiringEpisode")
            if na is not None and not all(isinstance(na.get(k), int) for k in ("episode", "airingAt", "timeUntilAiring")):
                problems.append(f"media {m.get('id')} nextAiringEpisode={na}")
            for k in ("averageScore", "meanScore", "popularity", "episodes", "duration", "seasonYear"):
                if m.get(k) is not None and not isinstance(m.get(k), int):
                    problems.append(f"media {m.get('id')} {k}={m.get(k)!r}")
    note("decode-check " + label, f"{len(problems)} problem(s): {problems[:30]}", "error" if problems else "notice")


def safe_json(raw, label):
    try:
        return json.loads(raw)
    except Exception:
        note(label, f"non-JSON: {raw[:400]!r}", "error")
        return {}


targets = []
user = os.environ.get("ANILIST_USER", "")
if SEASONS_ONLY: user = ""
if user == "Josh":
    user = ""
if user:
    status, raw, dt = run(query("userByName"), {"name": user})
    u = (json.loads(raw).get("data") or {}).get("User")
    note("userByName", f"HTTP {status} user={json.dumps(u)[:300]}")
    if u: targets.append((u["id"], "input:" + user))
# A heavy user (stress test) and a typical recently active user.
status, raw, dt = run("query { Page(perPage: 1) { users(sort: [WATCHED_TIME_DESC]) { id name } } }", {})
d = safe_json(raw, "users query")
note("users query", f"HTTP {status} {str(d)[:400]}")
for u in (((d.get("data") or {}).get("Page") or {}).get("users") or []):
    targets.append((u["id"], "top-watcher:" + u["name"]))
status, raw, dt = run("query { Page(perPage: 3) { activities(type: ANIME_LIST, sort: ID_DESC) { ... on ListActivity { user { id name } } } } }", {})
d = safe_json(raw, "activity query")
note("activity query", f"HTTP {status} {str(d)[:400]}")
for a in ((((d.get("data") or {}).get("Page") or {}).get("activities")) or [])[:2]:
    if a and a.get("user"): targets.append((a["user"]["id"], "recent:" + a["user"]["name"]))
for uid, label in targets:
    try:
        check_user(uid, label)
    except Exception as ex:
        import traceback
        note("crash " + label, traceback.format_exc(), "error")
    time.sleep(2)

for name, variables in [("browse", {"page": 1, "perPage": 25, "sort": ["TRENDING_DESC"], "isAdult": False}),
                        ("detail", {"id": 1})]:
    status, raw, dt = run(query(name), variables)
    data = json.loads(raw)
    note(name, f"HTTP {status} in {dt:.1f}s errors={data.get('errors')}",
         "notice" if status == 200 and not data.get("errors") else "error")


# Season collapse: mirrors Seasons.sameShow / Media.previousSeasonId in Models.swift.
import re
SERIES = {"TV", "TV_SHORT", "ONA"}
def norm(t): return "".join(c for c in (t or "").lower() if c.isalnum())
def same(a, b):
    for k in ("romaji", "english"):
        p, q = norm((a or {}).get(k)), norm((b or {}).get(k))
        if not p or not q: continue
        common = 0
        for x, y in zip(p, q):
            if x != y: break
            common += 1
        shorter = min(len(p), len(q))
        if common >= min(shorter, max(8, shorter * 6 // 10)): return True
    return False
ROMANS={"ii","iii","iv","vi","vii","viii","ix"}; UNITS={"season","part","cour"}
ORDW={"second","third","fourth","fifth","sixth","final"}
def words(s): return [w for w in re.split(r"[^\w]|_", (s or "").lower()) if w]
def is_count(w, before):
    if w in ROMANS: return True
    return w.isdigit() and 1<=int(w)<=20 and before in UNITS
def is_ord(w):
    if w in ORDW: return True
    return len(w)>=3 and w[:-2].isdigit() and int(w[:-2])>=1 and w[-2:] in ("st","nd","rd","th")
def split(t):
    w=words(t); n=len(w); ch=True
    while ch and len(w)>1:
        ch=False; last=w[-1]; before=w[-2] if len(w)>2 else ""
        if is_count(last, before):
            w=w[:-2] if before in UNITS else w[:-1]; ch=True
        elif last in UNITS and is_ord(before):
            w=w[:-2]
            if len(w)>1 and w[-1]=="the": w=w[:-1]
            ch=True
    return w, len(w)<n

def same_base(a, b):
    for k in ("romaji", "english"):
        p, q = split((a or {}).get(k))[0], split((b or {}).get(k))[0]
        if p and p == q: return True
    return False
def marked(t): return split((t or {}).get("romaji"))[1] or split((t or {}).get("english"))[1]

def prev_season(m):
    edges = [e for e in ((m.get("relations") or {}).get("edges") or [])
             if e.get("relationType") == "PREQUEL" and (e.get("node") or {}).get("type") in (None, "ANIME")
             and same(m.get("title"), (e.get("node") or {}).get("title"))]
    pick = next((e for e in edges if e["node"].get("format") in SERIES), edges[0] if edges else None)
    return pick["node"]["id"] if pick else None

for name, variables in [("browseWithRelations", {"page": 1, "perPage": 50, "sort": ["POPULARITY_DESC"], "isAdult": False}),
                        ("seedRecommendations", {"ids": [101280], "recsPage": 1})]:
    status, raw, dt = run(query(name), variables)
    data = safe_json(raw, name)
    note(name, f"HTTP {status} in {dt:.1f}s, {len(raw)//1024} KB, errors={data.get('errors')}",
         "notice" if status == 200 and not data.get("errors") else "error")
    time.sleep(1)

season_lines, season_batch = [], 1
for search in ["Tensei shitara Slime Datta Ken 3rd Season", "Re:Zero 3rd Season", "Shingeki no Kyojin Final Season", "Mushoku Tensei II", "Fairy Tail 100 Years Quest", "Kimetsu no Yaiba Yuukaku-hen", "Sword Art Online Alternative", "Overlord IV", "Spy x Family Season 2", "Kaiju No. 8 Season 2", "Bleach Sennen Kessen", "Haikyuu Second Season"]:
    time.sleep(1)
    status, raw, dt = run("query($s:String){ Media(search:$s, type: ANIME){ id format title { romaji english } relations { edges { relationType node { id type format title { romaji english } } } } } }", {"s": search})
    m = (safe_json(raw, search).get("data") or {}).get("Media") or {}
    chain = [f"{m.get('id')} {m.get('format')} {(m.get('title') or {}).get('romaji')}"]
    cur = m
    root = m
    later = m.get("format") in SERIES and marked(m.get("title")) and prev_season(m)
    for _ in range(8 if later else 0):
        pid = prev_season(cur)
        if not pid: break
        time.sleep(2.5)
        st, r2, _ = run(query("mediaByIds"), {"ids": [pid], "perPage": 1})
        items = ((safe_json(r2, "mediaByIds").get("data") or {}).get("Page") or {}).get("media") or []
        if not items: chain.append(f"{pid} (fetch failed HTTP {st})"); break
        cur = items[0]
        if cur.get("format") in SERIES and same_base(cur.get("title"), m.get("title")): root = cur
        chain.append(f"{cur['id']} {cur.get('format')} {(cur.get('title') or {}).get('romaji')}")
    chain.append(("LATER SEASON" if later else "OWN SHOW") + f" -> RECOMMEND: {root.get('id')} {(root.get('title') or {}).get('romaji')}")
    if len(chain) == 2:
        rels = [(e.get("relationType"), (e.get("node") or {}).get("id"), (e.get("node") or {}).get("format"),
                 ((e.get("node") or {}).get("title") or {}).get("romaji"), ((e.get("node") or {}).get("title") or {}).get("english"))
                for e in ((m.get("relations") or {}).get("edges") or [])]
        chain.append(f"title={m.get('title')} rels={rels}")
    season_lines.append(" -> ".join(chain))
    if len(season_lines) == 4:
        note(f"season batch {season_batch}", "\n".join(season_lines)); season_lines.clear(); season_batch += 1
    time.sleep(1)
if season_lines: note(f"season batch {season_batch}", "\n".join(season_lines))


# Taste twins (collaborative filtering): mirrors Services/TasteTwins.swift on a real list.
if os.environ.get("ANILIST_USER", "") == "twins":
    import math, random
    def gql(q, v):
        st, raw, dt = run(q, v)
        try: return json.loads(raw)
        except Exception: return {}
    me = gql(query("userByName"), {"name": "HARDWELL9191"})["data"]["User"]
    coll = gql(query("listCollection"), {"userId": me["id"]})["data"]["MediaListCollection"]
    entries = {}
    for l in coll["lists"]:
        if l.get("isCustomList"): continue
        for e in l["entries"]: entries[e["mediaId"]] = e
    scored = [e["score"] for e in entries.values() if e.get("score")]
    mean = sum(scored)/len(scored) if scored else 70
    spread = math.sqrt(sum((x-mean)**2 for x in scored)/len(scored)) if scored else 0
    def weight(e):  # mirrors Recommender.weight (scored part)
        s = e.get("score") or 0; st = e["status"]
        if s > 0:
            if st in ("COMPLETED","REPEATING","PLANNING"): return 0.3 + 1.7*(s/100)**2
            if st == "DROPPED": return -1
        return {"COMPLETED":0.7,"CURRENT":0.5,"PLANNING":0.5,"PAUSED":0.1,"DROPPED":-1}.get(st,0)
    W = {k: weight(e) for k,e in entries.items()}
    anchors = sorted([e for e in entries.values() if e["status"] in ("COMPLETED","REPEATING") and W[e["mediaId"]] > 0.5],
                     key=lambda e: -W[e["mediaId"]])[:6]
    hits = {}
    for a in anchors:
        time.sleep(2.2)
        d = gql(blocks["showFans"], {"mediaId": a["mediaId"], "page": random.randint(1,4)})
        for r in (((d.get("data") or {}).get("Page") or {}).get("mediaList") or []):
            if r.get("userId") and (r.get("score") or 0) >= 75: hits[r["userId"]] = hits.get(r["userId"],0)+1
    cands = sorted(random.sample(list(hits), len(hits)), key=lambda u: -hits[u])[:30]
    twins = []
    for u in cands:
        time.sleep(2.2)
        d = gql(blocks["ratingsOnly"], {"userId": u})
        rows = [e for l in ((((d.get("data") or {}).get("MediaListCollection") or {}).get("lists")) or []) for e in (l.get("entries") or [])]
        sc = [r["score"] for r in rows if (r.get("score") or 0) > 0]
        if len(sc) < 10: continue
        m = sum(sc)/len(sc); sd = max(8, math.sqrt(sum((x-m)**2 for x in sc)/len(sc)))
        prefs = {}
        for r in rows:
            if (r.get("score") or 0) > 0: prefs[r["mediaId"]] = max(-2, min(2, (r["score"]-m)/sd))
            elif r.get("status") == "DROPPED": prefs[r["mediaId"]] = -1
        agree = norm = 0; ov = 0
        for i, p in prefs.items():
            w = W.get(i, 0)
            if w and i in entries: agree += w*p; norm += w*w; ov += 1
        if ov < 2 or norm <= 0: continue
        sim = agree/math.sqrt(norm)*ov/(ov+4)
        if sim > 0.05: twins.append((sim, prefs))
    tot = sum(t[0] for t in twins) or 1
    summ, sup, seen = {}, {}, {}
    for sim, prefs in twins:
        for i, p in prefs.items():
            if i in entries: continue
            summ[i] = summ.get(i,0) + sim*p
            seen[i] = seen.get(i,0) + 1
            if p > 0.25: sup[i] = sup.get(i,0)+1
    raw = {i: v/math.sqrt(seen[i]) for i, v in summ.items() if sup.get(i,0) >= 2 and v > 0}
    top = sorted(raw.items(), key=lambda kv: -kv[1])[:20]
    ids = [i for i,_ in top]
    time.sleep(2.2)
    d = gql(query("mediaByIds"), {"ids": ids, "perPage": len(ids)})
    names = {m["id"]: f'{(m["title"].get("english") or m["title"].get("romaji"))} [{m.get("format")}{", adult" if m.get("isAdult") else ""}]'
             for m in (((d.get("data") or {}).get("Page") or {}).get("media") or [])}
    mx = top[0][1] if top else 1
    note("twins summary", f"your list: {len(entries)} entries, mean score {mean:.0f}; anchors={[ (entries[a['mediaId']]['media']['title'].get('english') or entries[a['mediaId']]['media']['title'].get('romaji')) for a in anchors]}; candidate people={len(hits)}, used={len(cands)}, twins found={len(twins)}, top similarities={sorted([round(t[0],2) for t in twins], reverse=True)[:8]}")
    note("twins top 1-10", "\n".join(f"{v/mx:.2f}  {names.get(i, i)}" for i, v in top[:10]))
    note("twins top 11-20", "\n".join(f"{v/mx:.2f}  {names.get(i, i)}" for i, v in top[10:20]))
