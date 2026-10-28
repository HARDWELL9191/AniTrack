# Is every later season reachable from its first season's dropdown? (username "branches")
exec(open("tools/seasons2_check.py").read().split("newly, both, nf")[0], globals())
t = lambda m: ((m.get("title") or {}).get("english") or (m.get("title") or {}).get("romaji") or "")[:34]
def link(m, kind):
    edges = [e for e in ((m.get("relations") or {}).get("edges") or []) if e.get("relationType") == kind and (e.get("node") or {}).get("type") in (None, "ANIME")]
    e = next((e for e in edges if e["node"].get("format") in SERIES), edges[0] if edges else None)
    return e["node"]["id"] if e else None
def chain(r):
    ids, cur, seen = [r["id"]], r, {r["id"]}
    for _ in range(12):
        nx = link(cur, "SEQUEL")
        if not nx or nx in seen: break
        seen.add(nx)
        if nx not in known: fetch([nx])
        if nx not in known: break
        cur = known[nx]
        if cur.get("format") in SERIES: ids.append(nx)
    return ids
missing, ok = [], 0
for m in later:
    r = root(m)[0]
    if not r: continue
    if m["id"] in chain(r): ok += 1
    else: missing.append(f"{t(m)} (first season {t(r)})")
note("branches", f"reachable from dropdown: {ok}\nNOT reachable: {len(missing)}\n" + "\n".join(missing))
