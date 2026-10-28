# The app's list request exactly as it's sent now (username "listcheck").
import json
st, raw, dt = run(query("userByName"), {"name": "HARDWELL9191"})
uid = json.loads(raw)["data"]["User"]["id"]
st, raw, dt = run(query("listCollection"), {"userId": uid})
try:
    d = json.loads(raw)
    lists = ((d.get("data") or {}).get("MediaListCollection") or {}).get("lists") or []
    note("listcheck", f"HTTP {st} in {dt:.1f}s, {len(raw)} bytes, lists {len(lists)}, entries {sum(len(l.get('entries') or []) for l in lists)}, errors {json.dumps(d.get('errors'))[:1500]}")
except Exception as e:
    note("listcheck", f"HTTP {st} non-JSON {raw[:800]!r}")
