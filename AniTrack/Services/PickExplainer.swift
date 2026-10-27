import Foundation
import FoundationModels

/// Writes a short "why you'll like it" blurb with Apple's on-device language model
/// (Foundation Models / Apple Intelligence). Runs only when the user asks for it on a card,
/// and results are cached in memory, so it costs nothing while you just browse.
@MainActor
final class PickExplainer {
    static let shared = PickExplainer()

    private var cache: [Int: String] = [:]

    enum Availability {
        case available
        case unavailable(String)
    }

    var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This device doesn't support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in Settings to use AI explanations.")
            case .modelNotReady:
                return .unavailable("Apple Intelligence is still downloading. Try again later.")
            @unknown default:
                return .unavailable("Apple Intelligence isn't available right now.")
            }
        }
    }

    func cached(_ mediaId: Int) -> String? { cache[mediaId] }

    func explain(_ rec: Recommendation, likedTitles: [String], language: TitleLanguage) async throws -> String {
        if let cached = cache[rec.id] { return cached }

        let session = LanguageModelSession(instructions: """
        You are the recommendation assistant in an anime tracking app. \
        In at most two short sentences (under 45 words total), tell the user why they may enjoy \
        the recommended anime, connecting it to anime they rated highly. \
        Be specific about tone, premise or characters. No spoilers, no markdown, no lists.
        """)

        let because = rec.because.isEmpty ? likedTitles.prefix(5).joined(separator: "; ")
                                          : rec.because.joined(separator: "; ")
        let prompt = """
        Anime the user rated highly: \(because)
        Themes they share: \(rec.sharedHighlights.joined(separator: ", "))
        Recommended anime: \(rec.media.displayTitle(language))
        Genres: \((rec.media.genres ?? []).joined(separator: ", "))
        Synopsis: \(String(rec.media.plainDescription.prefix(700)))
        """

        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[rec.id] = text
        return text
    }
}
