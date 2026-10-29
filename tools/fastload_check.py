# Tests "overnight season lookups" + "deeper links in one request" (username "fastload").
import json, time, urllib.request, urllib.error
exec(open("tools/seasons2_check.py").read().split("known = {}")[0], globals())   # rules: season(), later_new(), prequels()...

def post(q, v):
    body = json.dumps({"query": q, "variables": v}).encode()
    req = urllib.request.Request("https://graphql.anilist.co", data=body, headers={
        "Content-Type": "application/json", "Accept": "application/json", "User-Agent": UA})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read(); h = r.headers; st = r.status
    except urllib.error.HTTPError as e:
        raw = e.read(); h = e.headers; st = e.code
    return st, raw, time.time() - t, h.get("X-RateLimit-Limit"), h.get("X-RateLimit-Remaining")

base = query("browseWithRelations")
rel1 = blocks["relFragment"]
node = "id type format episodes title { romaji english }"
rel2 = ("fragment rel on Media {\n  relations { edges { relationType node { " + node +
        " relations { edges { relationType node { " + node + " } } } } } }\n}")
deep = base.replace(rel1, rel2)
from datetime import date
mo = date.today().month; yr = date.today().year
S = ["WINTER", "SPRING", "SUMMER", "FALL"]; si = (mo - 1) // 3
nxt = (S[(si + 1) % 4], yr + (1 if si == 3 else 0))
shelves = [{"sort": ["TRENDING_DESC", "POPULARITY_DESC"]},
           {"sort": ["POPULARITY_DESC"], "season": S[si], "seasonYear": yr},
           {"sort": ["POPULARITY_DESC"], "season": nxt[0], "seasonYear": nxt[1]},
           {"sort": ["SCORE_DESC"]}]
def vars_(s): v = {"page": 1, "perPage": 25, "isAdult": False, "formatNot": ["MOVIE"]}; v.update(s); return v
lines = []

# --- A) today: 4 shelves (one level of links) + hop-by-hop lookups -------------------------
st, _, _, limit, rem0 = post("query { Viewer { id } }", {})
lines.append(f"AniList rate limit: {limit}/min, remaining at start {rem0}")
time.sleep(3)
items, reqs, t0 = {}, 0, time.time()
for s in shelves:
    st, raw, dt, _, rem = post(base, vars_(s)); reqs += 1
    for m in ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media") or []: items[m["id"]] = m
later = [m for m in items.values() if later_new(m)]
known = dict(items)
def root_of(m, kn):
    cur, seen, r = m, {m["id"]}, None
    while True:
        p = prequel_id(cur)
        if not p or p in seen or len(seen) > 15: return r, None
        seen.add(p)
        if p not in kn: return r, p
        cur = kn[p]
        if season(cur.get("format"), cur.get("episodes")): r = cur
rounds = 0
for _ in range(10):
    miss = list({root_of(m, known)[1] for m in later if root_of(m, known)[1]})
    if not miss: break
    rounds += 1
    st, raw, dt, _, rem = post(query("mediaByIds"), {"ids": miss[:50], "perPage": min(len(miss), 50)}); reqs += 1
    for m in ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media") or []: known[m["id"]] = m
lines.append(f"A) today: {len(items)} shows, {len(later)} sequels, {reqs} requests ({rounds} lookup rounds), {time.time()-t0:.1f}s, remaining {rem}")
first_seasons = {m["id"]: root_of(m, known)[0] for m in later}

# --- B) deeper links (2 levels) in the shelf request itself ---------------------------------
time.sleep(5)
t0 = time.time(); reqs = 0; sizes = []; errors = []
items2 = {}
for s in shelves:
    st, raw, dt, _, rem = post(deep, vars_(s)); reqs += 1; sizes.append(len(raw))
    d = json.loads(raw)
    if d.get("errors"): errors.append(json.dumps(d["errors"])[:300])
    for m in ((d.get("data") or {}).get("Page") or {}).get("media") or []: items2[m["id"]] = m
# with 2 levels: S2 → S1 from level 1; S3 → S2 → S1 from level 2
def root_2levels(m):
    best = None
    for e in prequels(m):
        n = e["node"]
        if season(n.get("format"), n.get("episodes")): best = n
        for e2 in ((n.get("relations") or {}).get("edges") or []):
            n2 = e2.get("node") or {}
            if e2.get("relationType") == "PREQUEL" and same_show(m.get("title"), n2.get("title")) \
               and season(n2.get("format"), n2.get("episodes")): best = n2
    return best
later2 = [m for m in items2.values() if later_new(m)]
solved = sum(1 for m in later2 if root_2levels(m) and first_seasons.get(m["id"]) and root_2levels(m)["id"] == first_seasons[m["id"]]["id"])
lines.append(f"B) deeper links: {reqs} requests, {time.time()-t0:.1f}s, sizes {[f'{x//1024}KB' for x in sizes]}, "
             f"errors {errors or 'none'}, remaining {rem}")
lines.append(f"   sequels answered with NO extra request: {solved}/{len(later2)} (rest need {len(later2)-solved} lookups as today)")

# one-level sizes for comparison
time.sleep(2)
st, raw1, _, _, _ = post(base, vars_(shelves[0]))
st, raw2, _, _, rem = post(deep, vars_(shelves[0]))
lines.append(f"   trending shelf size: one level {len(raw1)//1024}KB vs two levels {len(raw2)//1024}KB")

# --- C) overnight job: this + next season + trending + top rated + popular, all first seasons --
# Deeper links are trusted only when they show the chain really ends there (the season found at
# level 1 has no same-show season before it); otherwise lookups continue from where they stop.
time.sleep(5)
t0 = time.time(); reqs = 0; pool = {}
for s in shelves + [{"sort": ["POPULARITY_DESC"], "season": S[si], "seasonYear": yr, "page": 2}]:
    st, raw, dt, _, rem = post(deep, vars_(s)); reqs += 1
    for m in ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media") or []: pool[m["id"]] = m
lat = [m for m in pool.values() if later_new(m)]
def sure_from_links(m):
    for e in prequels(m):
        n = e["node"]
        if not season(n.get("format"), n.get("episodes")): continue
        before = [e2 for e2 in ((n.get("relations") or {}).get("edges") or [])
                  if e2.get("relationType") == "PREQUEL" and same_show(n.get("title"), (e2.get("node") or {}).get("title"))]
        if not before: return n   # level-1 season with nothing of the same show before it: the first season
    return None
sure = {m["id"]: sure_from_links(m) for m in lat}
need = [m for m in lat if not sure[m["id"]]]
kk = dict(pool)
rounds = 0
for _ in range(10):
    miss = list({root_of(m, kk)[1] for m in need if root_of(m, kk)[1]})
    if not miss: break
    rounds += 1
    st, raw, dt, _, rem = post(query("mediaByIds"), {"ids": miss[:50], "perPage": min(len(miss), 50)}); reqs += 1
    for m in ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media") or []: kk[m["id"]] = m
answers = {m["id"]: (sure[m["id"]] or root_of(m, kk)[0]) for m in lat}
unresolved = [m for m in lat if not answers[m["id"]]]
# check against the full hop-by-hop answers from test A where we have them
checked = [m for m in lat if m["id"] in first_seasons and first_seasons[m["id"]]]
wrong = [m for m in checked if answers[m["id"]] and answers[m["id"]]["id"] != first_seasons[m["id"]]["id"]]
lines.append(f"C) overnight job: {len(pool)} shows, {len(lat)} sequels, {reqs} requests ({rounds} lookup rounds) in {time.time()-t0:.1f}s, remaining {rem}")
lines.append(f"   first seasons from links alone: {len(lat)-len(need)}, from lookups: {len(need)-len(unresolved)}, not found: {len(unresolved)}")
lines.append(f"   checked against full lookups: {len(checked)} sequels, wrong answers: {len(wrong)}"
             + (" (" + "; ".join((x['title'].get('english') or x['title'].get('romaji') or '')[:30] for x in wrong[:6]) + ")" if wrong else ""))
note("fastload", "\n".join(lines))
