# Checks the movie filter exactly as the app sends it (username "movies").
import json, time
lines = []
for name, v in [("browse, no search", {"page": 1, "perPage": 50, "sort": ["POPULARITY_DESC"], "isAdult": False, "formatNot": ["MOVIE"]}),
                ("browse, search 'your name'", {"page": 1, "perPage": 10, "sort": ["SEARCH_MATCH"], "isAdult": False, "search": "your name"})]:
    for q in ("browse", "browseWithRelations"):
        time.sleep(2)
        st, raw, _ = run(query(q), v)
        d = json.loads(raw)
        media = ((d.get("data") or {}).get("Page") or {}).get("media") or []
        movies = [m["title"].get("romaji") for m in media if m.get("format") == "MOVIE"]
        lines.append(f"{q} / {name}: HTTP {st}, {len(media)} shows, movies {len(movies)} {movies[:3]}, errors {d.get('errors')}")
note("movies check", "\n".join(lines))
