import Foundation
import FoundationModels

/// "Why would I like this?": two sentences from Apple's on-device language model
/// (Foundation Models / Apple Intelligence). Only runs when asked; cached in memory.
@MainActor
final class PickExplainer {
    static let shared = PickExplainer()
    private var cache: [String: String] = [:]

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

    func cached(_ id: String) -> String? { cache[id] }

    func explain(_ item: BaseItem, because: [String], liked: [String], highlights: [String], noun: String) async throws -> String {
        if let hit = cache[item.id] { return hit }
        let session = LanguageModelSession(instructions: """
        You are the recommendation assistant in a personal media player app. \
        In at most two short sentences (under 45 words total), tell the user why they may enjoy \
        the recommended \(noun), connecting it to titles they finished or loved. \
        Be specific about tone, premise or characters. No spoilers, no markdown, no lists.
        """)
        let basis = because.isEmpty ? liked.prefix(5).joined(separator: "; ") : because.joined(separator: "; ")
        let prompt = """
        Titles the user finished or loved: \(basis)
        Themes they share: \(highlights.joined(separator: ", "))
        Recommended \(noun): \(item.displayName)\(item.productionYear.map { " (\($0))" } ?? "")
        Genres: \((item.genres ?? []).joined(separator: ", "))
        Overview: \(String(item.plainOverview.prefix(700)))
        """
        let options = GenerationOptions(sampling: nil, temperature: 0.7, maximumResponseTokens: 120)
        let response = try await session.respond(to: prompt, options: options)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[item.id] = text
        return text
    }
}
