// Writes My List / Not for me exactly as the Windows app saves them (same functions as storage.ts),
// for the Swift side to decode with the iPhone's own model types; then reads what Swift wrote back.
// node gen.ts write <dir>   |   node gen.ts read <dir>
import { readFileSync, writeFileSync } from "node:fs";
import { encodeEntry, externalTitle, listEntryForServer, listEntryForTitle, myListEntry, slim, titleId } from "../../src/core/titles.ts";

const [mode, dir] = process.argv.slice(2);
if (mode === "write") {
  // A full title (as the TMDB client makes it), a bare one (only required fields), Japanese text,
  // and the first Windows builds' migrated shape.
  const full = externalTitle({ source: "tmdbTV", sourceId: 209867, title: "Frieren: Beyond Journey's End", originalTitle: "葬送のフリーレン", originalLanguage: "ja", year: 2023,
    overview: "Elf mage Frieren and her courageous fellow adventurers have defeated the Demon King. ".repeat(10), genres: ["Animation", "Action & Adventure", "Sci-Fi & Fantasy"],
    tags: ["magic", "elf", "journey", "based on manga", "seinen", "anime", "fantasy world", "adventure", "mage", "friendship"], posterURL: "https://image.tmdb.org/t/p/w500/abc.jpg",
    backdropURL: "https://image.tmdb.org/t/p/w1280/def.jpg", score: 8.8, voteCount: 512, popularity: 120.5, episodes: 28, seasons: 1, runtime: null, imdbId: "tt22248376", tvdbId: 424536, status: "Returning Series", isAdult: false, ageRating: "TV-14", ageRatingCountry: "US" })!;
  const bare = externalTitle({ source: "tmdbMovie", sourceId: 129, title: "Spirited Away", overview: "", genres: [], tags: [], isAdult: false })!;
  const migrated = externalTitle({ source: "tmdbMovie", sourceId: 372058, title: "Your Name.", overview: "Two strangers find themselves linked.", genres: ["Romance"], tags: [], isAdult: false, year: 2016, posterURL: "https://image.tmdb.org/t/p/w500/q719jXXEzOoYaps6babgKnONONX.jpg" })!;
  const myList = [listEntryForServer("a1b2c3d4e5f60718293a4b5c6d7e8f90", "Mushoku Tensei"), listEntryForTitle(full), listEntryForTitle(bare), listEntryForServer("ffff0000ffff0000ffff0000ffff0000", null)];
  writeFileSync(`${dir}/mylist.json`, JSON.stringify(myList.map(encodeEntry)));
  writeFileSync(`${dir}/notforme.json`, JSON.stringify([full, bare, migrated].map(slim)));
  console.log("wrote", myList.length, "My List entries and 3 titles");
} else {
  // What Swift wrote (JSONEncoder defaults: Date = seconds since 2001, URL = string).
  const list = (JSON.parse(readFileSync(`${dir}/swift-mylist.json`, "utf8")) as unknown[]).map(myListEntry);
  const titles = (JSON.parse(readFileSync(`${dir}/swift-titles.json`, "utf8")) as unknown[]).map(externalTitle);
  if (list.some((e) => !e) || titles.some((t) => !t)) { console.error("Windows couldn't read an entry the iPhone wrote"); process.exit(1); }
  const ids = list.map((e) => (e!.serverId ? `server:${e!.serverId}` : titleId(e!.external!)));
  console.log("read back from Swift:", ids.join(", "), "|", titles.map((t) => titleId(t!)).join(", "));
  const expect = ["server:a1b2c3d4e5f60718293a4b5c6d7e8f90", "tmdbTV:209867", "tmdbMovie:129", "server:ffff0000ffff0000ffff0000ffff0000"];
  if (ids.join() !== expect.join()) { console.error("Round trip changed the list:", ids); process.exit(1); }
  if (titles[0]!.ageRating !== "TV-14" || titles[0]!.ageRatingCountry !== "US") { console.error("The age rating the iPhone saves was lost:", titles[0]); process.exit(1); }
  const when = list[0]!.addedAt;
  if (!(when > 7e8 && when < 2e9)) { console.error("addedAt isn't Swift reference-date seconds:", when); process.exit(1); }
}
