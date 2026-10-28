# Mirrors SeasonChain + EpisodeService (Services/Kitsu.swift) on real shows.
import json, re, time
SERIES = {"TV", "TV_SHORT", "ONA"}
def media_by_ids(ids):
    st, raw, _ = run(query("mediaByIds"), {"ids": ids, "perPage": len(ids)})
    return {m["id"]: m for m in ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media", [])}
def link(m, t):
    edges = [e for e in ((m.get("relations") or {}).get("edges") or []) if e.get("relationType") == t and (e.get("node") or {}).get("type") in (None, "ANIME")]
    e = next((e for e in edges if e["node"].get("format") in SERIES), edges[0] if edges else None)
    return e["node"]["id"] if e else None
def chain(start_id):
    known = media_by_ids([start_id]); m0 = known[start_id]
    visited = {start_id}; before, after = [], []
    back, fwd = link(m0, "PREQUEL"), link(m0, "SEQUEL")
    for _ in range(12):
        want = [x for x in (back, fwd) if x and x not in known]
        if want: time.sleep(1.5); known.update(media_by_ids(want))
        moved = False
        if back and back not in visited and back in known:
            visited.add(back); m = known[back]
            if m.get("format") in SERIES: before.insert(0, m)
            back = link(m, "PREQUEL"); moved = True
        else: back = None
        if fwd and fwd not in visited and fwd in known:
            visited.add(fwd); m = known[fwd]
            if m.get("format") in SERIES: after.append(m)
            fwd = link(m, "SEQUEL"); moved = True
        else: fwd = None
        if not moved: break
    return before + [m0] + after
rx = re.compile(r"^(?:Episode|Ep\.?)\s*(\d+)\s*[-–—:]?\s*(.*)$", re.I)
def streaming(mid):
    st, raw, _ = run(query("streamingEpisodes"), {"id": mid})
    se = (((json.loads(raw).get("data") or {}).get("Media") or {}).get("streamingEpisodes")) or []
    out = []
    for i, e in enumerate(reversed(se)):
        mm = rx.match((e.get("title") or "").strip())
        n, t = (int(mm.group(1)), mm.group(2).strip() or None) if mm else (i + 1, e.get("title"))
        if n >= 1: out.append((n, t, bool(e.get("thumbnail"))))
    if out:
        first = min(n for n, _, _ in out)
        if first > 1: out = [(n - first + 1, t, th) for n, t, th in out]
    return out
lines = []
for start in [108511, 127720, 101922]:   # Slime S2, Mushoku Part 2, Demon Slayer S1
    c = chain(start)
    lines.append(f"start {start}: " + " | ".join(f"{(m['title'].get('english') or m['title'].get('romaji'))[:28]} ({m['format']},{m.get('episodes')})" for m in c))
    time.sleep(1.5)
note("episodes seasons", "\n".join(lines))
lines = []
for mid in [127720, 108511, 101280]:
    time.sleep(1.5)
    s = streaming(mid)
    m = media_by_ids([mid])[mid]
    lines.append(f"{(m['title'].get('english') or m['title'].get('romaji'))[:30]} (eps {m.get('episodes')}): " + "; ".join(f"{n}:{(t or '')[:22]}{'*' if th else ''}" for n, t, th in sorted(s)[:4]) + f" … total parsed {len(s)}")
note("episodes merge", "\n".join(lines))
