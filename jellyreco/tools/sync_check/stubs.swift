// What ExternalTitle.swift needs from the rest of the iPhone app (only the parts it references).
import Foundation
enum SemanticEngine {
    struct Input { let key: String; let text: String }
    static func stableKey(_ s: String) -> Int64 { Int64(s.count) }
}
enum Fmt { static func runtime(_ s: Double) -> String { "\(Int(s / 60))m" } }
