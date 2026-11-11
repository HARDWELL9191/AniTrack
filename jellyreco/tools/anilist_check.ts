// For You on the Anime / Anime Movies libraries (src/core/anilist.ts) against live AniList, with a
// small made-up list (no account needed): shows only for Anime, movies only for Anime Movies,
// nothing from the list, nothing already on the server, library names, the AniList title shape,
// and Kitsu's age ratings. The same checks as the iPhone app's AniListRecoUITests.
// node tools/anilist_check.ts
import {
  AniListClient, AniListOwnedIndex, aniListLibrary, anilistTitle, displayTitle, isMovieMedia, isLaterSeason, kitsuRatings, type ListEntry, type Media,
  recommend, setAniListStorage,
} from "../src/core/anilist.ts";
import { Queries } from "../src/core/anilistQueries.ts";
import { isAnime, isMovie, tmdbWebUrl } from "../src/core/titles.ts";

const memory = new Map<string, string>();
setAniListStorage({ get: (k) => memory.get(k) ?? null, set: (k, v) => void memory.set(k, v) });

const failures: string[] = [];
const check = (ok: boolean, what: string) => { if (ok) console.log("ok:", what); else { console.log("FAIL:", what); failures.push(what); } };

check(aniListLibrary("Anime") === "shows", "Anime = shows");
check(aniListLibrary("anime") === "shows", "anime = shows");
check(aniListLibrary("Anime Movies") === "movies", "Anime Movies = movies");
check(aniListLibrary("anime movies ") === "movies", "anime movies = movies");
check(aniListLibrary("Anime movies") === "movies", "Anime movies = movies");
check(aniListLibrary("TV Shows") === null, "TV Shows = TMDB");
check(aniListLibrary("Anime Shows") === null, "Anime Shows = TMDB");

const client = new AniListClient();
// Mushoku Tensei, Frieren, Solo Leveling, Re:Zero (shows), Your Name, A Silent Voice (movies).
const ids = [108465, 154587, 151807, 21355, 21519, 20954];
const page = await client.run<{ Page: { media: Media[] } }>(Queries.mediaByIds, { ids, perPage: ids.length });
if (page.Page.media.length < 4) { console.log("FAIL: couldn't load the seed shows"); process.exit(1); }
const entries: ListEntry[] = page.Page.media.map((m, i) => ({ id: -(i + 1), mediaId: m.id, status: "COMPLETED", score: 90, media: m }));
console.log("seeds:", entries.map((e) => displayTitle(e.media, "english")).join(" | "));
const onList = new Set(entries.map((e) => e.mediaId));
const options = (movies: boolean, owned = new AniListOwnedIndex()) => ({ hideChinese: true, includeUnreleased: false, dismissed: new Set<number>(), titleLanguage: "english" as const, useAI: false, category: null, movies, owned });

const shows = (await recommend(entries, client, options(false))).picks;
console.log(`shows: ${shows.length} —`, shows.slice(0, 6).map((p) => `${displayTitle(p.media, "english")} ${p.match}%`).join(" | "));
check(shows.length > 0, "Anime picks found");
check(shows.every((p) => !isMovieMedia(p.media)), "Anime picks are all shows");
check(shows.every((p) => !onList.has(p.media.id)), "Anime picks skip the list");
check(shows.every((p) => !isLaterSeason(p.media)), "Anime picks are first seasons");
check(shows.every((p) => p.match >= 50 && p.match <= 99), "match % in range");
check(new Set(shows.map((p) => p.media.id)).size === shows.length, "no duplicates");

const movies = (await recommend(entries, client, options(true))).picks;
console.log(`movies: ${movies.length} —`, movies.slice(0, 6).map((p) => `${displayTitle(p.media, "english")} ${p.match}%`).join(" | "));
check(movies.length > 0, "Anime Movies picks found");
check(movies.every((p) => isMovieMedia(p.media)), "Anime Movies picks are all movies");
check(movies.every((p) => !onList.has(p.media.id)), "Anime Movies picks skip the list");

// Already on the server: never picked (by title, and by the AniList id Jellyfin stored).
const top = shows[0]?.media;
if (top) {
  const name = top.title.english ?? top.title.romaji ?? "";
  const byName = new AniListOwnedIndex([{ Name: name, Type: "Series" }]);
  check(byName.contains(top), `server copy of ${name} is recognized by title`);
  check(byName.containsTitle(anilistTitle(top, "english")), "server copy recognized as a title");
  check(new AniListOwnedIndex([{ Name: "Something else", Type: "Series", ProviderIds: { AniList: String(top.id) } }]).contains(top), "server copy recognized by AniList id");
  const again = (await recommend(entries, client, options(false, byName))).picks;
  check(!again.some((p) => p.media.id === top.id), "owned show left out of picks");
  const movieTop = movies[0]?.media;
  if (movieTop) {
    const seriesSameName = new AniListOwnedIndex([{ Name: movieTop.title.english ?? movieTop.title.romaji ?? "", Type: "Series" }]);
    check(!seriesSameName.contains(movieTop), "a series with a movie's name doesn't hide the movie");
  }
}

// The title shape the cards, My List and the sheets use.
const m = entries[0].media;
const t = anilistTitle(m, "english");
check(t.source === "anilist" && t.sourceId === m.id && isAnime(t), "title is an AniList anime");
check(isMovie(t) === isMovieMedia(m), "title movie flag");
check(tmdbWebUrl(t) === `https://anilist.co/anime/${m.id}`, "title links to AniList");

const { found, failed } = await kitsuRatings(entries.slice(0, 3).map((e) => ({ id: e.mediaId, mal: e.media.idMal })));
console.log("kitsu:", failed ? "unreachable" : JSON.stringify(Object.fromEntries([...found].map(([k, v]) => [k, v.code]))));

if (failures.length) { console.log(`\n${failures.length} AniList check(s) failed: ${failures.join("; ")}`); process.exit(1); }
console.log("\nAniList checks passed");
