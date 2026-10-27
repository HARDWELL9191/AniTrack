"""Runs the app's GraphQL queries (read from AniListClient.swift) against AniList
and reports results as GitHub annotations, so they can be read through the API."""
import json
import os
import re
import time
import urllib.error
import urllib.request

SRC = open("AniTrack/Services/AniListClient.swift").read()
blocks = dict(re.findall(r'static let (\w+) = """\n(.*?)\n\s*"""', SRC, re.S))
fragment = blocks["mediaFragment"]
relfrag = blocks.get("relFragment", "")


def query(name):
    after = SRC.split(f"static let {name} = ")[1].split("static let")[0]
    return (blocks[name] + ("\n" + fragment if "+ mediaFragment" in after else "")
            + ("\n" + relfrag if "+ relFragment" in after else ""))


def note(title, msg, level="notice"):
    if os.environ.get("ANILIST_USER", "") == "seasons" and not title.startswith(("season", "browseWithRelations", "seedRecommendations", "mediaByIds")):
        return
    msg = str(msg).replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::{level} title={title}::{msg[:3500]}", flush=True)


UA = os.environ.get("TEST_UA", "AniTrack/1 CFNetwork/3860.100.1 Darwin/27.0.0")


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
import unicodedata
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
def prev_season(m):
    if m.get("format") not in SERIES: return None
    for e in ((m.get("relations") or {}).get("edges") or []):
        n = e.get("node") or {}
        if e.get("relationType") == "PREQUEL" and n.get("type") in (None, "ANIME") and n.get("format") in SERIES and same(m.get("title"), n.get("title")):
            return n["id"]
    return None

for name, variables in [("browseWithRelations", {"page": 1, "perPage": 50, "sort": ["POPULARITY_DESC"], "isAdult": False}),
                        ("seedRecommendations", {"ids": [101280], "recsPage": 1})]:
    status, raw, dt = run(query(name), variables)
    data = safe_json(raw, name)
    note(name, f"HTTP {status} in {dt:.1f}s, {len(raw)//1024} KB, errors={data.get('errors')}",
         "notice" if status == 200 and not data.get("errors") else "error")
    time.sleep(1)

for search in ["Tensei shitara Slime Datta Ken 2nd Season", "Mushoku Tensei II", "Bleach Sennen Kessen", "Shingeki no Kyojin Season 3", "Kimetsu no Yaiba Mugen Ressha", "Spy x Family Season 2"]:
    status, raw, dt = run("query($s:String){ Media(search:$s, type: ANIME){ id format title { romaji english } relations { edges { relationType node { id type format title { romaji english } } } } } }", {"s": search})
    m = (safe_json(raw, search).get("data") or {}).get("Media") or {}
    chain = [f"{m.get('id')} {m.get('format')} {(m.get('title') or {}).get('romaji')}"]
    cur = m
    for _ in range(6):
        pid = prev_season(cur)
        if not pid: break
        time.sleep(1)
        st, r2, _ = run(query("mediaByIds"), {"ids": [pid], "perPage": 1})
        items = ((safe_json(r2, "mediaByIds").get("data") or {}).get("Page") or {}).get("media") or []
        if not items: chain.append(f"{pid} (fetch failed HTTP {st})"); break
        cur = items[0]
        chain.append(f"{cur['id']} {cur.get('format')} {(cur.get('title') or {}).get('romaji')}")
    note("season " + search, " -> ".join(chain))
    time.sleep(1)
