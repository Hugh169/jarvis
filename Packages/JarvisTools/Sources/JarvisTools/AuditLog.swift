import Foundation

/// Append-only record of every tool invocation, at `~/.jarvis/audit.log` as
/// JSONL (spec §7).
///
/// The point is answering "what did it actually do" after the fact, so entries
/// are written even when a tool fails or the user declines it.
public actor AuditLog {
    public static let shared = AuditLog()

    public struct Entry: Codable, Sendable {
        public let timestamp: Date
        public let tool: String
        public let arguments: JSONValue
        public let outcome: String
        public let detail: String
        public let requiredConfirmation: Bool
        public let confirmed: Bool?
        public let durationMS: Int

        enum CodingKeys: String, CodingKey {
            case timestamp, tool, arguments, outcome, detail
            case requiredConfirmation = "required_confirmation"
            case confirmed
            case durationMS = "duration_ms"
        }
    }

    public enum Outcome: String, Sendable {
        case succeeded, failed, declined, dryRun = "dry_run"
    }

    private let url: URL
    private let encoder: JSONEncoder

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis", isDirectory: true)
            .appendingPathComponent("audit.log")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public var fileURL: URL { url }

    public func record(
        tool: String,
        arguments: JSONValue,
        outcome: Outcome,
        detail: String,
        requiredConfirmation: Bool,
        confirmed: Bool?,
        duration: TimeInterval
    ) {
        let entry = Entry(
            timestamp: .now,
            tool: tool,
            arguments: arguments,
            outcome: outcome.rawValue,
            // Keep the log readable; full output lives in the debug log.
            detail: String(detail.prefix(500)),
            requiredConfirmation: requiredConfirmation,
            confirmed: confirmed,
            durationMS: Int(duration * 1000)
        )
        guard let data = try? encoder.encode(entry) else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var line = data
        line.append(0x0A)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// Most recent entries first, for the Settings viewer.
    public func recent(limit: Int = 100) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .reversed()
            .prefix(limit)
            .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
