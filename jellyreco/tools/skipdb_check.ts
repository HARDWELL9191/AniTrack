// The open skip databases (src/core/skipdb.ts): the addresses built for an episode and a movie, the
// documented answers of TheIntroDB (API v4) and IntroDB turned into media segments, answers that
// must not be used (another episode, another shape, times that can't fit the file), the server's
// segments winning over the databases', and the lookup order. Then one live lookup in each
// database, reported but never failing the build (they are other people's servers). Anime: the
// anime ID list turned into MyAnimeList ID + episode, AniSkip's answers, and that anime never
// reaches the other two databases; then the real list and one live AniSkip lookup.
// node tools/skipdb_check.ts
import * as S from "../src/core/skipdb.ts";
import * as A from "../src/core/aniskip.ts";
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

// --- Anime: AniSkip only ---------------------------------------------------------------------------
// Entries as they are in the anime ID list (Attack on Titan, Frieren, Re:ZERO, One Piece, Mushoku Tensei, a movie).
const list = [
  { type: "TV", mal_id: 16498, anilist_id: 16498, anidb_id: 9541, tvdb_id: 267440, season: { tvdb: 1, tmdb: 1 }, themoviedb_id: { tv: 1429 }, imdb_id: ["tt2560140"] },
  { type: "OVA", mal_id: 18397, anilist_id: 18397, tvdb_id: 267440, season: { tvdb: 0, tmdb: 0 }, themoviedb_id: { tv: 1429 } },
  { type: "TV", mal_id: 35760, anilist_id: 99147, tvdb_id: 267440, season: { tvdb: 3, tmdb: 3 }, themoviedb_id: { tv: 1429 } },
  { type: "TV", mal_id: 38524, anilist_id: 104578, tvdb_id: 267440, season: { tvdb: 3, tmdb: 3 }, episode_offset: { tvdb: 12, tmdb: 12 }, themoviedb_id: { tv: 1429 } },
  { type: "TV", mal_id: 40028, tvdb_id: 267440, season: { tvdb: 4, tmdb: 4 }, themoviedb_id: { tv: 1429 } },
  { type: "TV", mal_id: 48583, tvdb_id: 267440, season: { tvdb: 4, tmdb: 4 }, episode_offset: { tvdb: 16, tmdb: 16 }, themoviedb_id: { tv: 1429 } },
  { type: "SPECIAL", mal_id: 51535, tvdb_id: 267440, season: { tvdb: 4, tmdb: 4 }, episode_offset: { tvdb: 28, tmdb: 28 }, themoviedb_id: { tv: 1429 } },
  { type: "TV", mal_id: 52991, anilist_id: 154587, tvdb_id: 424536, season: { tvdb: 1, tmdb: 1 }, themoviedb_id: { tv: 209867 } },
  { type: "TV", mal_id: 59978, anilist_id: 182255, tvdb_id: 424536, season: { tvdb: 2, tmdb: 1 }, episode_offset: { tmdb: 28 }, themoviedb_id: { tv: 209867 } },
  { type: "TV", mal_id: 31240, anilist_id: 21355, tvdb_id: 305089, season: { tvdb: 1, tmdb: 1 }, themoviedb_id: { tv: 65942 } },
  { type: "OVA", anilist_id: 100049, tvdb_id: 305089, season: { tvdb: 0, tmdb: 0 }, themoviedb_id: { tv: 65942 } },
  { type: "TV", mal_id: 39587, anilist_id: 108632, tvdb_id: 305089, season: { tvdb: 2, tmdb: 1 }, episode_offset: { tmdb: 26 }, themoviedb_id: { tv: 65942 } },
  { type: "TV", mal_id: 42203, anilist_id: 119661, tvdb_id: 305089, season: { tvdb: 2, tmdb: 1 }, episode_offset: { tvdb: 13, tmdb: 38 }, themoviedb_id: { tv: 65942 } },
  { type: "TV", mal_id: 21, anilist_id: 21, tvdb_id: 81797, themoviedb_id: { tv: 37854 }, imdb_id: ["tt0388629"] },
  { type: "MOVIE", mal_id: 459, anilist_id: 459, tvdb_id: 81797, season: { tvdb: 0 }, episode_offset: { tvdb: 1 }, themoviedb_id: { movie: [19576] }, imdb_id: ["tt0814243"] },
  { type: "TV", mal_id: 39535, tvdb_id: 371310, season: { tvdb: 1, tmdb: 1 }, themoviedb_id: { tv: 94664 } },
  { type: "TV", mal_id: 45576, tvdb_id: 371310, season: { tvdb: 1, tmdb: 1 }, episode_offset: { tvdb: 11, tmdb: 11 }, themoviedb_id: { tv: 94664 } },
  { type: "MOVIE", mal_id: 164, anilist_id: 164, themoviedb_id: { movie: [128] }, imdb_id: ["tt0119698"] },
];
assert.equal(A.buildAnimeIndex(list, 1), null);   // far too short to be the list
const index = A.buildAnimeIndex([...list, ...Array.from({ length: 1100 }, (_, i) => ({ type: "TV", mal_id: 900000 + i, tvdb_id: 9000000 + i, season: { tvdb: 1 } }))], Date.now())!;
A.setAnimeIndex(index);
const q = (o: Partial<A.AnimeQuery>): A.AnimeQuery => ({ movie: false, hint: false, ...o });
const T = (o: Partial<A.AnimeQuery>) => A.animeTargets(q(o));
assert.deepEqual(T({ tvdb: 267440, tmdb: 1429, season: 1, episode: 5 }), { anime: true, targets: [{ mal: 16498, episode: 5 }] });
assert.deepEqual(T({ tvdb: 267440, season: 3, episode: 12 }).targets, [{ mal: 35760, episode: 12 }]);
assert.deepEqual(T({ tvdb: 267440, season: 3, episode: 13 }).targets, [{ mal: 38524, episode: 1 }]);           // second cour
assert.deepEqual(T({ tvdb: 267440, season: 4, episode: 29 }).targets, [{ mal: 51535, episode: 1 }]);           // the final specials
assert.deepEqual(T({ tvdb: 267440, season: 0, episode: 1 }), { anime: true, targets: [] });                      // specials: anime, not looked up
assert.deepEqual(T({ tvdb: 267440, season: 9, episode: 1 }), { anime: true, targets: [] });
// Mushoku Tensei S1E12 is the second cour's first episode.
assert.deepEqual(T({ tvdb: 371310, season: 1, episode: 12 }).targets, [{ mal: 45576, episode: 1 }]);
// Frieren season 2: TVDB has it as season 2, TMDB as season 1 from episode 29.
assert.deepEqual(T({ tvdb: 424536, tmdb: 209867, season: 2, episode: 3 }).targets, [{ mal: 59978, episode: 3 }]);
assert.deepEqual(T({ tvdb: 424536, tmdb: 209867, season: 1, episode: 30, tvdbNumbering: false }).targets, [{ mal: 59978, episode: 2 }, { mal: 52991, episode: 30 }]);
// Re:ZERO with TMDB's numbers on a server that also knows the TVDB ID: both readings, the likelier first.
assert.deepEqual(T({ tvdb: 305089, tmdb: 65942, season: 1, episode: 27, tvdbNumbering: true }).targets, [{ mal: 31240, episode: 27 }, { mal: 39587, episode: 1 }]);
assert.deepEqual(T({ tvdb: 305089, tmdb: 65942, season: 2, episode: 14 }).targets, [{ mal: 42203, episode: 1 }]);
// One Piece: the list has no season for it, so season 1 in the show's own count.
assert.deepEqual(T({ tvdb: 81797, season: 1, episode: 500 }).targets, [{ mal: 21, episode: 500 }]);
// Anime metadata plugins' IDs name the entry directly.
assert.deepEqual(T({ anilist: 154587, season: 1, episode: 4 }), { anime: true, targets: [{ mal: 52991, episode: 4 }] });
assert.deepEqual(T({ anidb: 9541, season: 1, episode: 4 }).targets, [{ mal: 16498, episode: 4 }]);
assert.deepEqual(T({ mal: 52991, season: 1, episode: 4 }).targets, [{ mal: 52991, episode: 4 }]);
// Movies by TMDB or IMDb ID.
assert.deepEqual(T({ movie: true, tmdb: 128 }), { anime: true, targets: [{ mal: 164, episode: 1 }] });
assert.deepEqual(T({ movie: true, imdb: "tt0119698" }).targets, [{ mal: 164, episode: 1 }]);
// Not anime: nothing in the list and no hint. In an Anime library but unknown: anime, nowhere to look.
assert.deepEqual(T({ tvdb: 81189, tmdb: 1396, imdb: "tt0903747", season: 1, episode: 1 }), { anime: false, targets: [] });
assert.deepEqual(T({ tvdb: 81189, season: 1, episode: 1, hint: true }), { anime: true, targets: [] });
assert.deepEqual(T({ movie: true, tmdb: 603, imdb: "tt0133093" }), { anime: false, targets: [] });

// The address, and AniSkip's answers as they come (Frieren episode 1; Mushoku Tensei cour 2 episode 1).
assert.equal(A.aniSkipUrl({ mal: 52991, episode: 1 }, 1510102), "https://api.aniskip.com/v2/skip-times/52991/1?types=op&types=ed&types=mixed-op&types=mixed-ed&types=recap&episodeLength=1510.102");
assert.equal(A.aniSkipUrl({ mal: 52991, episode: 1 }, 0).endsWith("episodeLength=0"), true);
const anime = (durationMs: number) => ({ ...l, itemId: "a1", durationMs });
const mk = (len: number) => (source: string, type: any, start: number | null, end: number | null) => S.skipSegment(source, type, start, end, anime(len));
const frieren = { found: true, results: [{ interval: { startTime: 116.748, endTime: 206.748 }, skipType: "op", skipId: "x", episodeLength: 1510.092 }, { interval: { startTime: 1417.135, endTime: 1507.135 }, skipType: "ed", skipId: "y", episodeLength: 1510.102 }], message: "Successfully found skip times", statusCode: 200 };
assert.deepEqual(A.parseAniSkip(frieren, mk(1510102)).map((s) => [s.Type, s.StartTicks, s.EndTicks]), [["Intro", 1167480000, 2067480000], ["Outro", 14171350000, 15071350000]]);
const mushoku = { found: true, results: [{ interval: { startTime: 79.726, endTime: 169.726 }, skipType: "op" }, { interval: { startTime: 1324.125, endTime: 1373 }, skipType: "ed" }, { interval: { startTime: 0.625, endTime: 7.042 }, skipType: "mixed-op" }, { interval: { startTime: 30, endTime: 60 }, skipType: "recap" }] };
assert.deepEqual(A.parseAniSkip(mushoku, mk(1427000)).map((s) => s.Type), ["Intro", "Outro", "Recap"]);   // the mixed opening only without a plain one
assert.deepEqual(A.parseAniSkip({ found: true, results: [{ interval: { startTime: 0.625, endTime: 7.042 }, skipType: "mixed-op" }] }, mk(1427000)).map((s) => s.Type), ["Intro"]);
for (const b of [null, "x", { found: false, results: [] }, { results: [{ skipType: "op" }] }, { results: [{ interval: { startTime: 9, endTime: 3 }, skipType: "op" }] }, { results: [{ interval: { startTime: 1, endTime: 90 }, skipType: "other" }] }]) assert.equal(A.parseAniSkip(b, mk(1427000)).length, 0, JSON.stringify(b));

// The whole lookup: anime asks AniSkip and nothing else; the wrong reading (404) falls through to the next.
const item = (id: string, o: object) => ({ Id: id, Type: "Episode", RunTimeTicks: 1510.102 * 1e7, ProviderIds: {}, ...o }) as any;
const show = (ids: object, o: object = {}) => ({ Id: "s", Type: "Series", ProviderIds: ids, ...o }) as any;
calls = [];
const net = async (url: string) => {
  calls.push(url);
  if (url.includes("/31240/27?")) return new Response(JSON.stringify({ found: false, results: [], statusCode: 404 }), { status: 404 });
  if (url.includes("aniskip")) return new Response(JSON.stringify(frieren));
  return new Response(JSON.stringify({ season: 1, episode: 1, intro: [{ start_ms: 1000, end_ms: 9000 }] }));
};
S.setSkipDbFetch(net); A.setAniSkipFetch(net);
const all = ["Intro", "Recap", "Outro", "Preview"] as any;
r = await S.skipDbSegments(S.skipLookup(item("a2", { ParentIndexNumber: 1, IndexNumber: 27, ProviderIds: { Tvdb: "1" } }), show({ Tvdb: "305089", Tmdb: "65942", Imdb: "tt5607616" }))!, all);
assert.deepEqual(r.map((s) => s.Id), ["skipdb:aniskip:Intro:116748", "skipdb:aniskip:Outro:1417135"]);
assert.deepEqual(calls.map((u) => u.split("?")[0]), ["https://api.aniskip.com/v2/skip-times/31240/27", "https://api.aniskip.com/v2/skip-times/39587/1"]);
// Anime with no times in AniSkip: nothing, and still not a word to the other two databases.
calls = [];
r = await S.skipDbSegments(S.skipLookup(item("a3", { ParentIndexNumber: 9, IndexNumber: 1 }), show({ Tvdb: "267440", Imdb: "tt2560140" }))!, all);
assert.equal(r.length, 0); assert.equal(calls.length, 0);
// In the Anime library, or with the "Anime" genre, but unknown to the list: anime all the same.
r = await S.skipDbSegments(S.skipLookup(item("a4", { ParentIndexNumber: 1, IndexNumber: 1 }), show({ Tvdb: "81189", Imdb: "tt0903747" }), true)!, all);
assert.equal(r.length, 0); assert.equal(calls.length, 0);
r = await S.skipDbSegments(S.skipLookup(item("a5", { ParentIndexNumber: 1, IndexNumber: 1 }), show({ Tvdb: "81189", Imdb: "tt0903747" }, { Genres: ["Drama", "Anime"] }))!, all);
assert.equal(r.length, 0); assert.equal(calls.length, 0);
// Not anime: the other two as before, AniSkip never asked.
r = await S.skipDbSegments(S.skipLookup(item("a6", { ParentIndexNumber: 1, IndexNumber: 1 }), show({ Tmdb: "1396", Imdb: "tt0903747" }))!, all);
assert.deepEqual(r.map((s) => s.Id), ["skipdb:tidb:Intro:1000"]);
assert.equal(calls.some((u) => u.includes("aniskip")), false); assert.equal(calls.length, 2);
// An anime movie.
calls = [];
r = await S.skipDbSegments(S.skipLookup({ Id: "a7", Type: "Movie", RunTimeTicks: 1510.102 * 1e7, ProviderIds: { Tmdb: "128", Imdb: "tt0119698" } } as any, null)!, all);
assert.deepEqual(calls.map((u) => u.split("?")[0]), ["https://api.aniskip.com/v2/skip-times/164/1"]);
console.log("ok: anime goes to AniSkip only (ID list, seasons and cours, answers, lookup order)");

// Live: the real anime ID list, then Frieren S01E01 and Re:ZERO S02E14 through it to AniSkip.
A.setAniSkipFetch((url, init) => fetch(url, init));
A.setAnimeIndex(null);
const mem = new Map<string, string>();
A.setAniSkipStorage({ get: (k) => mem.get(k) ?? null, set: (k, v) => void mem.set(k, v) });
for (const [name, ids, season, episode, seconds] of [["Frieren S01E01", { Tvdb: "424536", Tmdb: "209867" }, 1, 1, 1510.102], ["Re:ZERO S02E14", { Tvdb: "305089", Tmdb: "65942" }, 2, 14, 0]] as const) {
  try {
    const lk = S.skipLookup(item(`live-${name}`, { ParentIndexNumber: season, IndexNumber: episode, RunTimeTicks: seconds * 1e7, ProviderIds: { Tvdb: "1" } }), show(ids))!;
    const found = await aniSkipLive(lk);
    console.log(`${found.segments.length ? "::notice::" : "::warning::"}AniSkip live lookup, ${name}: anime ${found.anime}, saved index ${Math.round((mem.get("skipdb.animeIndex.v1")?.length ?? 0) / 1024)} KB, ${found.segments.map((s) => `${s.Type} ${(s.StartTicks / 1e7).toFixed(1)}-${(s.EndTicks / 1e7).toFixed(1)}s`).join(", ") || "nothing"}`);
  } catch (e) {
    console.log(`::warning::AniSkip live lookup failed: ${e}`);
  }
}
function aniSkipLive(lk: S.SkipLookup) { return A.aniSkipSegments(lk.anime, lk.durationMs, (source, type, start, end) => S.skipSegment(source, type, start, end, lk)); }

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
