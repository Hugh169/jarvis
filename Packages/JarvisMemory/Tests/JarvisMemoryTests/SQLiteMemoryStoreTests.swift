import Foundation
import Testing
@testable import JarvisMemory

@Suite("SQLite memory store")
struct SQLiteMemoryStoreTests {
    /// A fresh file per test, deleted afterwards, so nothing touches
    /// `~/.jarvis/memory.sqlite`.
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-memory-\(UUID().uuidString).sqlite")
    }

    @Test("Facts survive closing and reopening the database")
    func persistsAcrossInstances() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = try SQLiteMemoryStore(url: url)
            try await store.remember(Fact(text: "Dad's car is a blue Volvo", category: "family"))
        }

        // The whole point of the phase: a new process must see it.
        let reopened = try SQLiteMemoryStore(url: url)
        let facts = try await reopened.allFacts()
        #expect(facts.count == 1)
        #expect(facts.first?.text == "Dad's car is a blue Volvo")
        #expect(facts.first?.category == "family")
    }

    @Test("Recall finds a fact by one of its words")
    func recallsByTerm() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        try await store.remember(Fact(text: "The wifi password is hunter2", category: "home"))
        try await store.remember(Fact(text: "Bin night is Tuesday", category: "home"))

        let hits = try await store.recall(matching: "wifi", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.text.contains("hunter2") == true)
    }

    /// The reason `matchExpression` exists. Spoken queries carry apostrophes,
    /// question marks and words FTS5 treats as operators; each of these is a
    /// syntax error if passed through raw.
    @Test("Punctuation and FTS operator words are searched literally, not as syntax")
    func sanitisesQueries() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        try await store.remember(Fact(text: "Dad's car needs a service", category: "family"))

        for query in [
            "what did I say about dad's car?",
            "dad AND car",
            "dad OR car",
            "NOT dad",
            "dad*",
            "\"dad",
            "car: dad",
            "NEAR dad",
        ] {
            let hits = try await store.recall(matching: query, limit: 10)
            #expect(hits.count == 1, "query failed to match: \(query)")
        }
    }

    @Test("A query with no searchable words returns nothing rather than throwing")
    func handlesEmptyQuery() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        try await store.remember(Fact(text: "Bin night is Tuesday", category: "home"))

        #expect(try await store.recall(matching: "", limit: 10).isEmpty)
        #expect(try await store.recall(matching: "   ", limit: 10).isEmpty)
        #expect(try await store.recall(matching: "?!*", limit: 10).isEmpty)
    }

    @Test("The better match ranks first")
    func ranksByRelevance() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        try await store.remember(Fact(text: "A note that mentions coffee once", category: "misc"))
        try await store.remember(Fact(text: "coffee coffee coffee", category: "misc"))

        let hits = try await store.recall(matching: "coffee", limit: 10)
        #expect(hits.count == 2)
        #expect(hits.first?.text == "coffee coffee coffee")
    }

    @Test("Limit is respected")
    func respectsLimit() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        for index in 0..<5 {
            try await store.remember(Fact(text: "coffee note \(index)", category: "misc"))
        }
        #expect(try await store.recall(matching: "coffee", limit: 3).count == 3)
    }

    @Test("Forgetting removes the fact and leaves the others")
    func forgets() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        let doomed = Fact(text: "Temporary thought", category: "misc")
        try await store.remember(doomed)
        try await store.remember(Fact(text: "Bin night is Tuesday", category: "home"))

        try await store.forget(id: doomed.id)

        let remaining = try await store.allFacts()
        #expect(remaining.count == 1)
        #expect(remaining.first?.text == "Bin night is Tuesday")
    }

    @Test("Forgetting an id that was never stored is not an error")
    func forgetIsIdempotent() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        try await store.forget(id: UUID())
        #expect(try await store.allFacts().isEmpty)
    }

    @Test("allFacts returns newest first")
    func ordersNewestFirst() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        let old = Fact(text: "Older", category: "misc", createdAt: Date(timeIntervalSince1970: 1_000))
        let new = Fact(text: "Newer", category: "misc", createdAt: Date(timeIntervalSince1970: 2_000))
        try await store.remember(old)
        try await store.remember(new)

        #expect(try await store.allFacts().map(\.text) == ["Newer", "Older"])
    }

    @Test("Dates and ids round-trip intact")
    func roundTripsFields() async throws {
        let store = try SQLiteMemoryStore(url: nil)
        let fact = Fact(text: "Round trip", category: "misc", createdAt: Date(timeIntervalSince1970: 1_234_567))
        try await store.remember(fact)

        let stored = try #require(try await store.allFacts().first)
        #expect(stored.id == fact.id)
        #expect(stored.category == fact.category)
        #expect(abs(stored.createdAt.timeIntervalSince1970 - 1_234_567) < 0.001)
    }
}
