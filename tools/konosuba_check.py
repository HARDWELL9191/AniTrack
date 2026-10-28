# How AniList links one franchise, and what the app decides (username "konosuba").
exec(open("tools/seasons2_check.py").read().split("pool = {}")[0], globals())
lines = []
for term in ["Arifureta", "Kono Subarashii Sekai ni"]:
    time.sleep(2)
    st, raw, _ = run(query("browseWithRelations"), {"page": 1, "perPage": 20, "search": term, "sort": ["SEARCH_MATCH"]})
    for m in ((json.loads(raw).get("data") or {}).get("Page") or {}).get("media") or []:
        if any(l.startswith(f"{m['id']} ") for l in lines): continue
        edges = [f"{e['relationType']}:{e['node'].get('format')}:{(e['node'].get('title') or {}).get('romaji','')[:40]}"
                 for e in ((m.get("relations") or {}).get("edges") or []) if e.get("relationType") in ("PREQUEL", "SEQUEL")]
        lines.append(f"{m['id']} {m.get('format')} {m['title'].get('romaji','')[:50]} / {(m['title'].get('english') or '')[:40]} | later={later_new(m)} | " + "; ".join(edges))
note("konosuba", "\n".join(lines))
