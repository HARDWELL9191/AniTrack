// The open skip databases (src/core/skipdb.ts): the addresses built for an episode and a movie, the
// documented answers of TheIntroDB (API v4) and IntroDB turned into media segments, answers that
// must not be used (another episode, another shape, times that can't fit the file), the server's
// segments winning over the databases', and the lookup order. Then one live lookup in each
// database, reported but never failing the build (they are other people's servers).
// node tools/skipdb_check.ts
import * as S from "../src/core/skipdb.ts";
import assert from "node:assert/strict";

const ep = { Id: "e1", Type: "Episode", ParentIndexNumber: 1, IndexNumber: 1, RunTimeTicks: 3500 * 1e7, ProviderIds: { Tvdb: "349232", Imdb: "tt0959621" } } as any;
const series = { Id: "s", Type: "Series", ProviderIds: { Tvdb: "81189", Tmdb: "1396", IMDB: "tt0903747" }, DisplayOrder: "aired" } as any;
const l = S.skipLookup(ep, series)!;
assert.equal(S.theIntroDbUrl(l), "https://api.theintrodb.org/v4/media?tvdb_id=81189&tvdb_episode_id=349232&season=1&episode=1&duration_ms=3500000");
assert.equal(S.introDbUrl(l), "https://api.introdb.app/segments?imdb_id=tt0903747&season=1&episode=1");
// no episode tvdb id -> tmdb
const l2 = S.skipLookup({ ...ep, ProviderIds: {} }, series)!;
assert.equal(S.theIntroDbUrl(l2), "https://api.theintrodb.org/v4/media?tmdb_id=1396&season=1&episode=1&duration_ms=3500000");
const l3 = S.skipLookup({ ...ep, ProviderIds: {} }, { ...series, ProviderIds: { Tvdb: "81189" }, DisplayOrder: "DVD" })!;
assert.equal(S.theIntroDbUrl(l3), "https://api.theintrodb.org/v4/media?tvdb_id=81189&mapping=dvd&season=1&episode=1&duration_ms=3500000");
const mv = S.skipLookup({ Id: "m", Type: "Movie", RunTimeTicks: 8181 * 1e7, ProviderIds: { Tmdb: "603", Imdb: "tt0133093" } } as any, null)!;
assert.equal(S.theIntroDbUrl(mv), "https://api.theintrodb.org/v4/media?tmdb_id=603&duration_ms=8181000");
assert.equal(S.introDbUrl(mv), "https://api.introdb.app/segments?imdb_id=tt0133093&is_movie=true");
assert.equal(S.skipLookup({ ...ep, IndexNumberEnd: 2 }, series), null);
assert.equal(S.skipLookup({ ...ep, ProviderIds: {} }, { ...series, ProviderIds: {} }), null);
assert.equal(S.skipLookup({ ...ep, IndexNumber: null }, series), null);
// documented v4 body
const a = S.parseTheIntroDb({ tvdb_id: 81189, type: "tv", season: 1, episode: 1, intro: [{ start_ms: 228583, end_ms: 246569 }], credits: [{ start_ms: 3431000, end_ms: null }] }, l);
assert.deepEqual(a.map((s) => [s.Type, s.StartTicks, s.EndTicks]), [["Intro", 2285830000, 2465690000], ["Outro", 34310000000, 35000000000]]);
// null start intro
assert.deepEqual(S.parseTheIntroDb({ intro: [{ start_ms: null, end_ms: 14600 }] }, l).map((s) => [s.StartTicks, s.EndTicks]), [[0, 146000000]]);
// wrong episode echoed (unpinned) -> nothing
assert.equal(S.parseTheIntroDb({ season: 1, episode: 2, intro: [{ start_ms: 0, end_ms: 30000 }] }, l2).length, 0);
// versions / episodes / junk bodies
for (const b of [null, [], "x", { versions: [] }, { episodes: [{}] }, { intro: "no" }, { intro: [{ start_ms: null, end_ms: null }] }, { intro: [{ start_ms: 3000000, end_ms: 3100000 }] }, { credits: [{ start_ms: 100, end_ms: 5000 }] }, { intro: [{ start_ms: 5000, end_ms: 5500 }] }]) assert.equal(S.parseTheIntroDb(b, l).length, 0, JSON.stringify(b));
// credits with unknown runtime and no end -> dropped; with end -> kept
const l0 = { ...l, durationMs: 0 };
assert.equal(S.parseTheIntroDb({ credits: [{ start_ms: 3431000, end_ms: null }] }, l0).length, 0);
assert.equal(S.parseTheIntroDb({ credits: [{ start_ms: 3431000, end_ms: 3480000 }] }, l0).length, 1);
// IntroDB documented body
const b = S.parseIntroDb({ imdb_id: "tt0903747", intro: { start_sec: 2.5, end_sec: 58, start_ms: 2500, end_ms: 58000, confidence: 0.92 }, recap: null, outro: { start_sec: 3400, end_sec: 3490 }, post_credits: null, no_intro: false }, l);
assert.deepEqual(b.map((s) => [s.Type, s.StartTicks, s.EndTicks]), [["Intro", 25000000, 580000000], ["Outro", 34000000000, 34900000000]]);
assert.equal(S.parseIntroDb({ intro: null, recap: null, outro: null }, l).length, 0);
// merge: server types win
const server = [{ Id: "x", ItemId: "e1", Type: "Intro", StartTicks: 1, EndTicks: 2 }] as any;
assert.deepEqual(S.mergeSegments(server, a).map((s) => s.Id), ["x", a[1].Id]);
// fetch flow: TIDB has intro only, IDB fills outro, not intro; cached
let calls: string[] = [];
S.setSkipDbFetch(async (url) => { calls.push(url); return url.includes("theintrodb") ? new Response(JSON.stringify({ season: 1, episode: 1, intro: [{ start_ms: 228583, end_ms: 246569 }] })) : new Response(JSON.stringify({ intro: { start_ms: 1000, end_ms: 9000 }, outro: { start_ms: 3400000, end_ms: 3490000 }, recap: null })); });
let r = await S.skipDbSegments(l, ["Intro", "Recap", "Outro", "Preview"]);
assert.deepEqual(r.map((s) => s.Id), ["skipdb:tidb:Intro:228583", "skipdb:idb:Outro:3400000"]);
r = await S.skipDbSegments(l, ["Outro"]); assert.equal(r.length, 1); assert.equal(calls.length, 2);
// 404 + network failure
calls = [];
S.setSkipDbFetch(async (url) => { calls.push(url); if (url.includes("theintrodb")) return new Response("{}", { status: 404 }); throw new Error("offline"); });
r = await S.skipDbSegments({ ...l, itemId: "e2" }, ["Intro"]); assert.equal(r.length, 0);
r = await S.skipDbSegments({ ...l, itemId: "e2" }, ["Intro"]); assert.equal(calls.length, 4);   // not cached: asked again
S.setSkipDbFetch(async () => new Response("<html>", { status: 200 }));
r = await S.skipDbSegments({ ...l, itemId: "e3" }, ["Intro"]); assert.equal(r.length, 0);
S.setSkipDbFetch(async () => new Response("{}", { status: 429 }));
r = await S.skipDbSegments({ ...l, itemId: "e4" }, ["Intro"]); assert.equal(r.length, 0);
console.log("ok: addresses, answers, merge and lookup order");

// Live: Breaking Bad S01E01 (TVDB 81189, IMDb tt0903747), which both databases document.
S.setSkipDbFetch((url, init) => fetch(url, init));
const live = S.skipLookup({ Id: "live", Type: "Episode", ParentIndexNumber: 1, IndexNumber: 1, RunTimeTicks: 3500 * 1e7, ProviderIds: {} } as any, series)!;
const fmt = (list: { Type: string; StartTicks: number; EndTicks: number }[]) => list.map((s) => `${s.Type} ${(s.StartTicks / 1e7).toFixed(1)}-${(s.EndTicks / 1e7).toFixed(1)}s`).join(", ") || "nothing";
for (const [name, url, parse] of [["TheIntroDB", S.theIntroDbUrl({ ...live, tmdb: undefined }), S.parseTheIntroDb], ["IntroDB", S.introDbUrl(live), S.parseIntroDb]] as const) {
  try {
    const r = await fetch(url!, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(15000) });
    const found = r.ok ? parse(await r.json(), live) : [];
    console.log(`${found.length ? "::notice::" : "::warning::"}${name} live lookup: HTTP ${r.status}, ${fmt(found)}`);
  } catch (e) {
    console.log(`::warning::${name} live lookup failed: ${e}`);
  }
}
