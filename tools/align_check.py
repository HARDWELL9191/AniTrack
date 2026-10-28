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

placeholder = re.compile(r"(?i)(?:episode|ep\.?)\s*\d+|untitled|tba|tbd|n/a")
def real(t):
    t = (t or "").strip()
    return None if not t or placeholder.fullmatch(t) else t

def titles(eps):
    out = {}
    for n, t in eps:
        if n not in out and real(t): out[n] = real(t)
    return out

def alignment(anilist, kitsu, later, expected, ktotal):
    too_long = bool(later and expected and ktotal and ktotal > expected * 1.5 + 2)
    a, k = titles(anilist), titles(kitsu)
    shared = sorted(n for n in a if n in k)[:8]
    if len(shared) < 2:
        kind = "A-titles-only" if a and not k else ("K-titles-only" if k and not a else ("none" if not a and not k else "no-overlap"))
        return ("anilistOnly-size" if too_long else "same-unchecked:" + kind), len(shared), 0
    m = sum(1 for n in shared if similar(a[n], k[n]))
    if m * 2 >= len(shared): return "same", len(shared), m
    return ("anilistOnly-size" if too_long else "kitsuOnly"), len(shared), m

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

stats, kitsu_only, other, same = {}, [], [], []
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
    verdict, sh, mt = alignment(a, k, later, m.get("episodes"), ktotal)
    stats[verdict] = stats.get(verdict, 0) + 1
    at, kt = titles(a), titles(k)
    pair = lambda n: f"{n}: A='{(at.get(n) or '')[:24]}' K='{(kt.get(n) or '')[:24]}'"
    line = f"{title} ({'later' if later else 'S1'}, eps {m.get('episodes')}, kitsu {ktotal}) {mt}/{sh}"
    if verdict == "kitsuOnly":
        kitsu_only.append(line + " | " + pair(sorted(at)[0]))
    elif verdict == "same":
        if mt < sh: same.append(line + " | " + " ; ".join(pair(n) for n in sorted(at)[:2]))
    else:
        other.append(f"{verdict}: {line} A{len(at)} K{len(kt)} | " + "; ".join(f"{n}:{(t or '')[:20]}" for n, t in sorted(a)[:2]))

note("align2 stats", json.dumps(stats))
note("align2 kitsuOnly", "\n".join(kitsu_only) or "none")
note("align2 unchecked or size", "\n".join(other[:40]) or "none")
note("align2 same but some differ", "\n".join(same[:25]) or "none")
