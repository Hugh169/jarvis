import Foundation

/// Model routing per the build plan §4. Sonnet is the default; an
/// `escalate_to_deep_reasoning` tool hands off to Opus mid-turn; Haiku is
/// reserved for background jobs (memory summarization, cheap classification).
public enum ModelTier: String, CaseIterable, Sendable, Codable {
    case fast = "claude-haiku-4-5"
    case standard = "claude-sonnet-5"
    case deep = "claude-opus-5"

    public var modelID: String { rawValue }

    /// Short names for the CLI harness and Settings.
    public init?(shortName: String) {
        switch shortName.lowercased() {
        case "fast", "haiku": self = .fast
        case "standard", "sonnet": self = .standard
        case "deep", "opus": self = .deep
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .fast: "Haiku 4.5 — fastest"
        case .standard: "Sonnet 5 — default"
        case .deep: "Opus 5 — deepest"
        }
    }

    /// Per-response output cap. Voice replies are short; deep/agentic turns get room.
    public var defaultMaxTokens: Int {
        switch self {
        case .fast: 1024
        case .standard: 4096
        case .deep: 16000
        }
    }
}
