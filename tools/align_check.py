# Mirrors EpisodeService.kitsuAlignment (Services/Kitsu.swift) on real shows: does Kitsu's
# episode N match AniList's episode N? Run through tools/api_check.py with username "align".
import json, re, time
_src = open("tools/kitsu_check.py").read()
exec(_src.split("lines = []")[0], globals())   # kget()
BASE = "https://kitsu.app/api/edge"
rx = re.compile(r"^(?:Episode|Ep\.?)\s*(\d+)(\.\d+)?\s*[-–—:]?\s*(.*)$", re.I)
generic = re.compile(r"^(?:episode|ep\.?|第)\s*\d+\s*(?:話)?$", re.I)

def words(s):
    return {w for w in re.split(r"[^\w]+", s.lower()) if len(w) > 2 and w != "_"}

def similar(a, b):
    x, y = words(a), words(b)
    if not x or not y: return a.lower() == b.lower()
    return len(x & y) / min(len(x), len(y)) >= 0.5

def titles(eps):
    return {n: t for n, t in eps if t and not generic.match(t.strip())}

def score(a, k, shift):
    shared = sorted(n for n in a if (n + shift) in k)[:8]
    return len(shared), sum(1 for n in shared if similar(a[n], k[n + shift]))

def alignment(anilist, kitsu, later, expected, ktotal):
    a, k = titles(anilist), titles(kitsu)
    s0, m0 = score(a, k, 0)
    if s0 < 2:
        if later and expected and ktotal and ktotal > expected * 1.5 + 2: return ("mismatch-size", 0, s0, m0)
        return ("same-unchecked", 0, s0, m0)
    if m0 * 2 >= s0: return ("same", 0, s0, m0)
    best = None
    for s in range(1, max(k) if k else 1):
        sh, mt = score(a, k, s)
        if sh >= 2 and mt * 4 >= sh * 3 and mt > (best[2] if best else 0): best = (s, sh, mt)
    if best: return ("shifted", best[0], best[1], best[2])
    return ("mismatch", 0, s0, m0)

def streaming(mid, later, expected):
    for attempt in range(3):
        st, raw, _ = run(query("streamingEpisodes"), {"id": mid})
        if st == 200: break
        time.sleep(30)
    se = (((json.loads(raw).get("data") or {}).get("Media") or {}).get("streamingEpisodes")) or []
    out = []
    for i, e in enumerate(reversed(se)):
        mm = rx.match((e.get("title") or "").strip())
        n, t, sp = (int(mm.group(1)), mm.group(3).strip() or None, mm.group(2) is not None) if mm else (i + 1, e.get("title"), False)
        if n >= 1 and not sp: out.append((n, t))
    if out:
        first = min(n for n, _ in out)
        if first > 1:
            if not later: return []
            out = [(n - first + 1, t) for n, t in out]
        elif later and expected and len(out) > expected * 1.5 + 2:
            return []
    return out

def kitsu_eps(mid, mal):
    for site, ext in (("anilist/anime", mid), ("myanimelist/anime", mal)):
        if not ext: continue
        st, d, _, _ = kget(f"{BASE}/mappings?filter[externalSite]={site}&filter[externalId]={ext}&include=item&fields[anime]=episodeCount")
        inc = [x for x in d.get("included", []) if x.get("type") == "anime"]
        if inc: break
    else:
        return None, None
    kid = inc[0]["id"]
    st, d, _, _ = kget(f"{BASE}/anime/{kid}/episodes?page[limit]=20&page[offset]=0&sort=number&fields[episodes]=number,canonicalTitle,description,synopsis")
    eps = [(r["attributes"].get("number"), (r["attributes"].get("canonicalTitle") or "").strip() or None)
           for r in d.get("data", []) if r.get("attributes", {}).get("number")]
    return eps, (d.get("meta") or {}).get("count")

# Sample: Tim's list + the most popular shows + popular sequels (later parts are the risky case).
pool = {}
me = json.loads(run(query("userByName"), {"name": "HARDWELL9191"})[1])["data"]["User"]
time.sleep(1)
coll = json.loads(run(query("listCollection"), {"userId": me["id"]})[1])["data"]["MediaListCollection"]
for l in coll["lists"]:
    if l.get("isCustomList"): continue
    for e in l["entries"]: pool.setdefault(e["media"]["id"], e["media"])
mine = list(pool)
for page in (1, 2):
    time.sleep(2)
    st, raw, _ = run(query("browseWithRelations"), {"page": page, "perPage": 50, "sort": ["POPULARITY_DESC"], "isAdult": False})
    for m in (json.loads(raw).get("data") or {}).get("Page", {}).get("media", []): pool.setdefault(m["id"], m)
time.sleep(2)
st, raw, _ = run(query("mediaByIds"), {"ids": mine[:45], "perPage": 45})   # with relations
for m in (json.loads(raw).get("data") or {}).get("Page", {}).get("media", []): pool[m["id"]] = m
ids = mine[:45] + [i for i in pool if i not in mine][:75]

stats, problems, shifted, same = {}, [], [], []
for mid in ids:
    m = pool[mid]
    if m.get("format") in ("MOVIE", "MUSIC") or m.get("episodes") == 1: continue
    later = any(e.get("relationType") == "PREQUEL" and (e.get("node") or {}).get("type") in (None, "ANIME")
                for e in ((m.get("relations") or {}).get("edges") or []))
    time.sleep(2.2)
    a = streaming(mid, later, m.get("episodes"))
    k, ktotal = kitsu_eps(mid, m.get("idMal"))
    title = (m["title"].get("english") or m["title"].get("romaji") or "")[:30]
    if k is None:
        stats["no kitsu"] = stats.get("no kitsu", 0) + 1; continue
    verdict, shift, sh, mt = alignment(a, k, later, m.get("episodes"), ktotal)
    stats[verdict] = stats.get(verdict, 0) + 1
    at, kt = titles(a), titles(k)
    pair = lambda n: f"{n}: A='{(at.get(n) or '')[:26]}' K='{(kt.get(n + shift) or '')[:26]}'"
    line = f"{title} ({'later' if later else 'S1'}, eps {m.get('episodes')}, kitsu {ktotal}) {verdict} {mt}/{sh}"
    if verdict.startswith("mismatch"):
        problems.append(line + " | " + " ; ".join(pair(n) for n in sorted(at)[:3]))
    elif verdict == "shifted":
        shifted.append(line + f" shift {shift} | " + " ; ".join(pair(n) for n in sorted(at)[:2]))
    elif verdict == "same" and mt < sh:
        same.append(line + " | " + " ; ".join(pair(n) for n in sorted(at)[:2]))

note("align stats", json.dumps(stats))
note("align mismatches", "\n".join(problems) or "none")
note("align shifted", "\n".join(shifted) or "none")
note("align same but some titles differ", "\n".join(same[:25]) or "none")
