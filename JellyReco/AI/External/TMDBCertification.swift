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
        // Only certifications that map to a bubble count (an unknown local code never shows).
        for c in [region, "US", "GB"].compactMap({ $0 }) { if let v = byCountry[c], bucket(v) != nil { return (v, c) } }
        for c in byCountry.keys.sorted() { if let v = byCountry[c], bucket(v) != nil { return (v, c) } }
        return nil
    }

    /// AniReco's four age bubbles: PG (everything under 13), 13+ (13–16), 17+, 18+.
    static func bucket(_ certification: String) -> String? {
        let c = clean(certification).uppercased()
        // Systems whose letters carry the age (US film and TV, UK, Australia, Canada, Japan…).
        let named: [String: String] = [
            "G": "PG", "PG": "PG", "U": "PG", "L": "PG", "E": "PG", "TP": "PG", "AL": "PG", "ALL": "PG", "A": "PG",
            "TV-Y": "PG", "TV-Y7": "PG", "TV-Y7-FV": "PG", "TV-G": "PG", "TV-PG": "PG", "12A": "PG", "PG12": "PG",
            "PG-13": "13+", "TV-14": "13+", "M": "13+", "14A": "13+", "MA15+": "13+", "R15+": "13+",
            "R": "17+", "TV-MA": "17+",
            "NC-17": "18+", "R18": "18+", "R18+": "18+", "X": "18+", "X18+": "18+", "18A": "18+", "R-18": "18+",
        ]
        if let label = named[c] { return label }
        // Jellyfin stores many ratings with a country in front ("DE-16", "GB-15", "AU-M").
        if let dash = c.firstIndex(of: "-"), c.distance(from: c.startIndex, to: dash) == 2,
           c.prefix(2).allSatisfy(\.isLetter), !["TV", "PG", "NC"].contains(String(c.prefix(2))) {
            let rest = String(c[c.index(after: dash)...])
            if let label = named[rest] { return label }
            return bucket(rest)
        }
        // Everything else by its age number ("12", "FSK 16", "K-15", "R-13", "19"…).
        guard let range = c.range(of: #"\d+"#, options: .regularExpression), let age = Int(c[range]) else { return nil }
        switch age {
        case ..<13: return "PG"
        case 13...16: return "13+"
        case 17: return "17+"
        default: return "18+"
        }
    }

    private static func clean(_ v: String) -> String { v.trimmingCharacters(in: .whitespaces) }

    private static func usable(_ v: String) -> Bool {
        let t = clean(v)
        return !t.isEmpty && !["NR", "UR", "UNRATED", "NOT RATED"].contains(t.uppercased())
    }
}
