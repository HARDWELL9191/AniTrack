// Age bubbles, exactly as the iPhone app does them (JellyReco/AI/External/TMDBCertification.swift):
// AniReco's four labels PG / 13+ / 17+ / 18+, from Jellyfin's OfficialRating on server titles and
// from TMDB's certification on For You picks.

const NAMED: Record<string, string> = {
  "G": "PG", "PG": "PG", "U": "PG", "L": "PG", "E": "PG", "TP": "PG", "AL": "PG", "ALL": "PG", "A": "PG",
  "TV-Y": "PG", "TV-Y7": "PG", "TV-Y7-FV": "PG", "TV-G": "PG", "TV-PG": "PG", "12A": "PG", "PG12": "PG",
  "PG-13": "13+", "TV-14": "13+", "M": "13+", "14A": "13+", "MA15+": "13+", "R15+": "13+",
  "R": "17+", "TV-MA": "17+",
  "NC-17": "18+", "R18": "18+", "R18+": "18+", "X": "18+", "X18+": "18+", "18A": "18+", "R-18": "18+",
};

/** PG (everything under 13), 13+ (13–16), 17+, 18+, or null for a rating that doesn't say. */
export function ageBucket(certification: string | null | undefined): string | null {
  if (!certification) return null;
  const c = certification.trim().toUpperCase();
  if (!c) return null;
  if (NAMED[c]) return NAMED[c];
  // Jellyfin stores many ratings with a country in front ("DE-16", "GB-15", "AU-M").
  const dash = c.indexOf("-");
  if (dash === 2 && /^[A-Z]{2}$/.test(c.slice(0, 2)) && !["TV", "PG", "NC"].includes(c.slice(0, 2))) {
    const rest = c.slice(3);
    return NAMED[rest] ?? ageBucket(rest);
  }
  // Everything else by its age number ("12", "FSK 16", "K-15", "R-13", "19"…).
  const m = c.match(/\d+/);
  if (!m) return null;
  const age = Number(m[0]);
  return age < 13 ? "PG" : age <= 16 ? "13+" : age === 17 ? "17+" : "18+";
}

const usable = (v: string) => { const t = v.trim(); return !!t && !["NR", "UR", "UNRATED", "NOT RATED"].includes(t.toUpperCase()); };

/** The device's country ("SI"), the first choice for TMDB's certification, as on the iPhone. */
export function deviceRegion(): string | null {
  for (const tag of [...(navigator.languages ?? []), navigator.language]) {
    const r = tag?.match(/[-_]([A-Za-z]{2})\b/)?.[1];
    if (r) return r.toUpperCase();
  }
  return null;
}

/** TMDB's certification and its country: the device's region first, then the US, the UK, then
 *  any country (only certifications that map to a bubble count). Movies read `release_dates`
 *  (theatrical first), shows `content_ratings`. */
export function pickCertification(json: Record<string, unknown>, tv: boolean, region: string | null): [string, string] | null {
  const byCountry = new Map<string, string>();
  if (tv) {
    const results = ((json.content_ratings as { results?: { iso_3166_1?: string; rating?: string }[] })?.results) ?? [];
    for (const r of results) if (r.iso_3166_1 && r.rating && usable(r.rating)) byCountry.set(r.iso_3166_1, r.rating.trim());
  } else {
    type Rel = { type?: number; certification?: string };
    const results = ((json.release_dates as { results?: { iso_3166_1?: string; release_dates?: Rel[] }[] })?.results) ?? [];
    // Type 3 = theatrical, then limited (2), digital (4), physical (5), TV (6), premiere (1).
    const order = [3, 2, 4, 5, 6, 1];
    const rank = (d: Rel) => { const i = order.indexOf(d.type ?? 0); return i < 0 ? 9 : i; };
    for (const r of results) {
      if (!r.iso_3166_1) continue;
      const v = [...(r.release_dates ?? [])].sort((a, b) => rank(a) - rank(b)).map((d) => d.certification ?? "").find(usable);
      if (v) byCountry.set(r.iso_3166_1, v.trim());
    }
  }
  for (const c of [region, "US", "GB"]) {
    const v = c ? byCountry.get(c) : undefined;
    if (v && ageBucket(v)) return [v, c!];
  }
  for (const c of [...byCountry.keys()].sort()) {
    const v = byCountry.get(c)!;
    if (ageBucket(v)) return [v, c];
  }
  return null;
}
