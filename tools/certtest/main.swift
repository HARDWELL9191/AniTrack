import Foundation

// TMDB response shapes (from TMDB's API reference: /movie/{id}/release_dates, /tv/{id}/content_ratings).
let movie = """
{"id":27205,"release_dates":{"results":[
 {"iso_3166_1":"DE","release_dates":[{"certification":"12","descriptors":[],"iso_639_1":"","note":"","release_date":"2010-07-29T00:00:00.000Z","type":3}]},
 {"iso_3166_1":"US","release_dates":[
   {"certification":"","descriptors":[],"iso_639_1":"","note":"Premiere","release_date":"2010-07-08T00:00:00.000Z","type":1},
   {"certification":"PG-13","descriptors":[],"iso_639_1":"","note":"","release_date":"2010-07-16T00:00:00.000Z","type":3},
   {"certification":"NR","descriptors":[],"iso_639_1":"","note":"","release_date":"2010-12-07T00:00:00.000Z","type":5}]}]}}
"""
let tv = """
{"id":1396,"content_ratings":{"results":[
 {"descriptors":[],"iso_3166_1":"DE","rating":"16"},
 {"descriptors":[],"iso_3166_1":"US","rating":"TV-MA"},
 {"descriptors":[],"iso_3166_1":"BR","rating":"16"}]}}
"""
let unrated = """
{"id":1,"content_ratings":{"results":[{"iso_3166_1":"US","rating":"NR"},{"iso_3166_1":"KR","rating":"15"}]}}
"""
let none = "{\"id\":2,\"release_dates\":{\"results\":[]}}"

func j(_ s: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any] }
var failed = 0
func check(_ name: String, _ got: (String, String)?, _ want: (String, String)?) {
    let ok = got?.0 == want?.0 && got?.1 == want?.1
    print("RESULT \(name): \(got.map { "\($0.0) (\($0.1))" } ?? "none") \(ok ? "OK" : "WRONG, want \(want.map { "\($0.0) (\($0.1))" } ?? "none")")")
    if !ok { failed += 1 }
}
check("movie, phone in Slovenia", TMDBCertification.pick(j(movie), tv: false, region: "SI"), ("PG-13", "US"))
check("movie, phone in Germany", TMDBCertification.pick(j(movie), tv: false, region: "DE"), ("12", "DE"))
check("show, phone in Slovenia", TMDBCertification.pick(j(tv), tv: true, region: "SI"), ("TV-MA", "US"))
check("show, phone in Germany", TMDBCertification.pick(j(tv), tv: true, region: "DE"), ("16", "DE"))
check("show only rated NR in US", TMDBCertification.pick(j(unrated), tv: true, region: "SI"), ("15", "KR"))
check("movie without ratings", TMDBCertification.pick(j(none), tv: false, region: "SI"), nil)
// The bubbles (AniReco's: PG under 13, 13+ for 13–16, 17+, 18+).
let buckets: [(String, String?)] = [
    ("G", "PG"), ("PG", "PG"), ("PG-13", "13+"), ("R", "17+"), ("NC-17", "18+"),
    ("TV-Y", "PG"), ("TV-Y7", "PG"), ("TV-G", "PG"), ("TV-PG", "PG"), ("TV-14", "13+"), ("TV-MA", "17+"),
    ("U", "PG"), ("12A", "PG"), ("12", "PG"), ("15", "13+"), ("18", "18+"), ("R18", "18+"),
    ("0", "PG"), ("6", "PG"), ("7", "PG"), ("16", "13+"), ("19", "18+"), ("MA15+", "13+"), ("R18+", "18+"),
    ("FSK 12", "PG"), ("DE-16", "13+"), ("GB-15", "13+"), ("AU-M", "13+"), ("DE-18", "18+"), ("FR-U", "PG"), ("K-15", "13+"), ("14A", "13+"), ("PG12", "PG"), ("R15+", "13+"), ("??", nil),
]
for (cert, want) in buckets {
    let got = TMDBCertification.bucket(cert)
    print("RESULT bubble \(cert) -> \(got ?? "none") \(got == want ? "OK" : "WRONG, want \(want ?? "none")")")
    if got != want { failed += 1 }
}
exit(failed == 0 ? 0 : 1)
