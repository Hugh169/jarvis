import Foundation

extension String {
    /// Number of non-overlapping occurrences of `needle`.
    func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while let found = range(of: needle, range: searchStart..<endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}

public struct Fact: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var category: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, category: String, createdAt: Date = .now) {
        self.id = id
        self.text = text
        self.category = category
        self.createdAt = createdAt
    }
}

/// Storage abstraction behind the remember/recall/forget tools.
/// Phase 5 replaces the in-memory implementation with GRDB + FTS5.
public protocol MemoryStore: Sendable {
    func remember(_ fact: Fact) async throws
    func recall(matching query: String, limit: Int) async throws -> [Fact]
    func forget(id: UUID) async throws
    func allFacts() async throws -> [Fact]
}

/// Keyword-scored in-memory store — enough to develop the tool loop against.
public actor InMemoryStore: MemoryStore {
    private var facts: [Fact] = []

    public init() {}

    public func remember(_ fact: Fact) async throws {
        facts.append(fact)
    }

    public func recall(matching query: String, limit: Int = 10) async throws -> [Fact] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return facts
            .map { fact -> (Fact, Int) in
                let haystack = fact.text.lowercased()
                // Score by total term occurrences, not distinct terms matched —
                // otherwise every fact containing the whole query ties and
                // ranking degrades to insertion order.
                let score = terms.reduce(0) { $0 + haystack.occurrences(of: $1) }
                return (fact, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    public func forget(id: UUID) async throws {
        facts.removeAll { $0.id == id }
    }

    public func allFacts() async throws -> [Fact] {
        facts
    }
}
