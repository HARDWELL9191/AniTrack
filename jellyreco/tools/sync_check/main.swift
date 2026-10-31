// Decodes the Windows app's lists with the iPhone app's own types and decoder settings, then writes
// lists the way the iPhone does for the Windows side to read back.
import Foundation
let dir = CommandLine.arguments[1]
func data(_ name: String) -> Data { try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)")) }
do {
    // Exactly as AppModel.decodeList / decodeTitles (JSONDecoder() with defaults).
    let list = try JSONDecoder().decode([MyListEntry].self, from: data("mylist.json"))
    let titles = try JSONDecoder().decode([ExternalTitle].self, from: data("notforme.json"))
    print("iPhone decoded \(list.count) My List entries: \(list.map(\.id))")
    print("iPhone decoded \(titles.count) titles: \(titles.map(\.id)), first poster \(titles.first?.posterURL?.absoluteString ?? "-")")
    guard list.count == 4, titles.count == 3, list[1].external?.title == "Frieren: Beyond Journey's End", list[1].external?.tags.count == 8,
          (list[1].external?.overview.count ?? 0) <= 400, titles[0].imdbId == "tt22248376", titles[0].ageRating == "TV-14", titles[0].ageRatingCountry == "US", list[0].addedAt.timeIntervalSinceNow > -300 else {
        print("::error::The iPhone read different values than the Windows app wrote"); exit(1)
    }
    // As AppModel.encodeList / encodeTitles write them.
    try JSONEncoder().encode(list).write(to: URL(fileURLWithPath: "\(dir)/swift-mylist.json"))
    try JSONEncoder().encode(titles).write(to: URL(fileURLWithPath: "\(dir)/swift-titles.json"))
} catch {
    print("::error::The iPhone app can't read the Windows app's lists: \(error)")
    exit(1)
}
