import Foundation
import Observation

/// Age ratings for the covers on screen. Covers ask as they appear; requests are gathered for
/// a moment and sent as one batch (up to 20 shows per request). Ratings are saved for good by
/// KitsuClient, so a cover you've seen before shows its rating instantly, with no request.
@Observable
@MainActor
final class AgeRatings {
    private(set) var ratings: [Int: AgeRating] = [:]

    @ObservationIgnored private var requested: Set<Int> = []
    @ObservationIgnored private var pending: Set<Int> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func rating(for mediaId: Int) -> AgeRating? { ratings[mediaId] }

    func request(_ mediaId: Int) {
        guard ratings[mediaId] == nil, !requested.contains(mediaId) else { return }
        requested.insert(mediaId)
        pending.insert(mediaId)
        guard task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)   // collect the covers that just appeared
            await self?.flush()
        }
    }

    private func flush() async {
        while !pending.isEmpty {
            let batch = Array(pending.prefix(20))
            pending.subtract(batch)
            let saved = await KitsuClient.shared.savedRatings(for: batch)
            if !saved.isEmpty { ratings.merge(saved) { _, new in new } }
            let missing = batch.filter { saved[$0] == nil }
            guard !missing.isEmpty else { continue }
            let (found, failed) = await KitsuClient.shared.ratings(for: missing)
            if !found.isEmpty { ratings.merge(found) { _, new in new } }
            if failed {
                // Kitsu unreachable: forget these so they're asked again next time they appear.
                requested.subtract(missing.filter { found[$0] == nil })
                requested.subtract(pending)
                pending.removeAll()
            }
        }
        task = nil
    }
}
