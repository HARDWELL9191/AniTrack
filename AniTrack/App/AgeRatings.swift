import Foundation
import Observation

/// Age ratings for the covers on screen. Covers ask as they appear; requests are gathered for
/// a moment and sent in batches. Ratings are saved for good by KitsuClient, so a cover you've
/// seen before shows its rating instantly, with no request.
@Observable
@MainActor
final class AgeRatings {
    private(set) var ratings: [Int: AgeRating] = [:]

    @ObservationIgnored private var requested: Set<Int> = []
    @ObservationIgnored private var pending: [Int: KitsuClient.Lookup] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    func rating(for mediaId: Int) -> AgeRating? { ratings[mediaId] }

    func request(_ media: Media) {
        guard ratings[media.id] == nil, !requested.contains(media.id) else { return }
        requested.insert(media.id)
        pending[media.id] = KitsuClient.Lookup(id: media.id, mal: media.idMal)
        guard task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)   // collect the covers that just appeared
            await self?.flush()
        }
    }

    private func flush() async {
        while !pending.isEmpty {
            let batch = Array(pending.values.prefix(30))
            for lookup in batch { pending[lookup.id] = nil }
            let saved = await KitsuClient.shared.savedRatings(for: batch.map(\.id))
            if !saved.isEmpty { ratings.merge(saved) { _, new in new } }
            let missing = batch.filter { saved[$0.id] == nil }
            guard !missing.isEmpty else { continue }
            let (found, failed) = await KitsuClient.shared.ratings(for: missing)
            if !found.isEmpty { ratings.merge(found) { _, new in new } }
            if failed {
                // Kitsu unreachable: forget these so they're asked again next time they appear.
                requested.subtract(missing.map(\.id).filter { found[$0] == nil })
                requested.subtract(pending.keys)
                pending.removeAll()
            }
        }
        task = nil
    }
}
