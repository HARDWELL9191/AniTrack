import Foundation

/// TMDB's age certification for a title. Foundation only, so CI compiles this exact file into a
/// test against TMDB's response shapes.
enum TMDBCertification {
    /// The certification and its country: `region` (your phone's) first, then the US, the UK,
    /// then any country. Movies read `release_dates` (theatrical release preferred), shows
    /// `content_ratings` — both added to the details request with append_to_response.
    static func pick(_ json: [String: Any], tv: Bool, region: String?) -> (String, String)? {
        var byCountry: [String: String] = [:]
        if tv {
            for r in ((json["content_ratings"] as? [String: Any])?["results"] as? [[String: Any]]) ?? [] {
                if let c = r["iso_3166_1"] as? String, let v = r["rating"] as? String, usable(v) { byCountry[c] = clean(v) }
            }
        } else {
            for r in ((json["release_dates"] as? [String: Any])?["results"] as? [[String: Any]]) ?? [] {
                guard let c = r["iso_3166_1"] as? String else { continue }
                let dates = (r["release_dates"] as? [[String: Any]]) ?? []
                // Type 3 = theatrical, then limited (2), digital (4), physical (5), TV (6), premiere (1).
                let order = [3, 2, 4, 5, 6, 1]
                func rank(_ d: [String: Any]) -> Int { order.firstIndex(of: (d["type"] as? Int) ?? 0) ?? 9 }
                let sorted = dates.sorted { rank($0) < rank($1) }
                if let v = sorted.compactMap({ $0["certification"] as? String }).first(where: { usable($0) }) {
                    byCountry[c] = clean(v)
                }
            }
        }
        for c in [region, "US", "GB"].compactMap({ $0 }) { if let v = byCountry[c] { return (v, c) } }
        if let c = byCountry.keys.sorted().first, let v = byCountry[c] { return (v, c) }
        return nil
    }

    private static func clean(_ v: String) -> String { v.trimmingCharacters(in: .whitespaces) }

    private static func usable(_ v: String) -> Bool {
        let t = clean(v)
        return !t.isEmpty && !["NR", "UR", "UNRATED", "NOT RATED"].contains(t.uppercased())
    }
}
