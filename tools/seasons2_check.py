# Mirrors Media.isLaterSeason + the first-season lookup (username "seasons2").
import json, re, time
SERIES = {"TV", "TV_SHORT", "ONA"}
def season(fmt, eps): return fmt in SERIES and (eps if eps is not None else 3) >= 3
def norm(s): return "".join(ch for ch in (s or "").lower() if ch.isalnum())
def same_show(a, b):
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
ROMANS = {"ii","iii","iv","vi","vii","viii","ix"}; UNITS = {"season","part","cour"}
ORD = {"second","third","fourth","fifth","sixth","final"}
def words(s): return [w for w in re.split(r"[^\w]+", (s or "").lower()) if w and w != "_"]
def is_ord(w):
    if w in ORD: return True
    return len(w) >= 3 and w[:-2].isdigit() and int(w[:-2]) >= 1 and w[-2:] in ("st","nd","rd","th")
def marked(t):
    w = words(t); n = len(w); ch = True
    while ch and len(w) > 1:
        ch = False; last = w[-1]; before = w[-2] if len(w) > 2 else ""
        if last in ROMANS or (last.isdigit() and 1 <= int(last) <= 20 and before in UNITS):
            w = w[:-2] if before in UNITS else w[:-1]; ch = True
        elif last in UNITS and is_ord(before):
            w = w[:-2]; ch = True
            if len(w) > 1 and w[-1] == "the": w = w[:-1]
    return len(w) < n
def has_marker(t): return marked((t or {}).get("romaji")) or marked((t or {}).get("english"))
def prequels(m):
    return [e for e in ((m.get("relations") or {}).get("edges") or [])
            if e.get("relationType") == "PREQUEL" and (e.get("node") or {}).get("type") in (None, "ANIME")
            and same_show(m.get("title"), e["node"].get("title"))]
def ends_number(t):
    for k in ("romaji", "english"):
        w = words((t or {}).get(k))
        if len(w) > 1 and w[-1].isdigit() and 2 <= int(w[-1]) <= 20: return True
    return False
def later_new(m):
    if not season(m.get("format"), m.get("episodes")): return False
    p = prequels(m)
    if any(season(e["node"].get("format"), e["node"].get("episodes")) for e in p): return True
    return bool(p) and (has_marker(m.get("title")) or ends_number(m.get("title")))
def later_old(m): return m.get("format") in SERIES and has_marker(m.get("title")) and bool(prequels(m))
def prequel_id(m):
    p = prequels(m)
    e = next((e for e in p if e["node"].get("format") in SERIES), p[0] if p else None)
    return e["node"]["id"] if e else None
known = {}
def fetch(ids):
    for i in range(0, len(ids), 50):
        for attempt in range(3):
            st, raw, _ = run(query("mediaByIds"), {"ids": ids[i:i+50], "perPage": len(ids[i:i+50])})
            if st == 200: break
            time.sleep(30)
        for m in ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media") or []: known[m["id"]] = m
        time.sleep(1.5)
def root(m):
    cur, seen, r = m, {m["id"]}, None
    while True:
        p = prequel_id(cur)
        if not p or p in seen or len(seen) > 15: return r, None
        seen.add(p)
        if p not in known: return r, p
        cur = known[p]
        if season(cur.get("format"), cur.get("episodes")): r = cur
pool = {}
def add(q, v):
    time.sleep(2)
    st, raw, _ = run(query(q), v)
    for m in ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media") or []: pool.setdefault(m["id"], m)
from datetime import date
mo = date.today().month; yr = date.today().year
seasons = ["WINTER","SPRING","SUMMER","FALL"]; si = (mo - 1) // 3
nxt = (seasons[(si + 1) % 4], yr + (1 if si == 3 else 0))
for v in [{"sort": ["TRENDING_DESC","POPULARITY_DESC"]}, {"sort": ["POPULARITY_DESC"], "season": seasons[si], "seasonYear": yr},
          {"sort": ["POPULARITY_DESC"], "season": nxt[0], "seasonYear": nxt[1]}, {"sort": ["SCORE_DESC"]},
          {"sort": ["POPULARITY_DESC"]}, {"sort": ["POPULARITY_DESC"], "page": 2}]:
    vv = {"page": 1, "perPage": 50, "isAdult": False, "formatNot": ["MOVIE"]}; vv.update(v)
    add("browseWithRelations", vv)
fetch([113415, 20, 1735, 97940, 21, 11061, 136430, 140960, 100668, 112323, 154473, 136804])   # JJK, Naruto, Shippuden, Black Clover, One Piece, HxH 2011, Vinland S2, Spy x Family S2
pool.update({k: v for k, v in known.items()})
for m in pool.values(): known.setdefault(m["id"], m)
later = [m for m in pool.values() if later_new(m)]
for _ in range(10):
    miss = list({root(m)[1] for m in later if root(m)[1]})
    if not miss: break
    fetch(miss)
newly, both, nf = [], [], []
t = lambda m: ((m.get("title") or {}).get("english") or (m.get("title") or {}).get("romaji") or "")[:34]
for m in pool.values():
    n, o = later_new(m), later_old(m)
    if n and not (any(season(e["node"].get("format"), e["node"].get("episodes")) for e in prequels(m)) or has_marker(m.get("title"))):
        nf.append("NUMBER RULE: " + t(m) + " -> " + (t(root(m)[0]) if root(m)[0] else "no root"))
    if n:
        r = root(m)[0]
        line = f"{t(m)} ({m['format']}) -> {t(r) + ' (' + r['format'] + ')' if r else 'NO ROOT (kept)'}"
        (both if o else newly).append(line)
    elif m["id"] in (113415, 20, 21, 11061, 97940, 100668):
        nf.append(f"{t(m)}: not a later season (correct for a first season)")
note("seasons2 new detections", "\n".join(sorted(newly)) or "none")
note("seasons2 already detected", "\n".join(sorted(both))[:3400] or "none")
note("seasons2 first seasons", "\n".join(nf) + f"\npool {len(pool)} shows, later {len(later)}")
