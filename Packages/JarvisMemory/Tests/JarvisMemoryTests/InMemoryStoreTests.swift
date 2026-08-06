import Testing
import Foundation
@testable import JarvisMemory

@Suite struct InMemoryStoreTests {
    @Test func rememberAndRecall() async throws {
        let store = InMemoryStore()
        try await store.remember(Fact(text: "the physics prac is due Friday", category: "school"))
        try await store.remember(Fact(text: "Preferred voice is George", category: "preferences"))

        let hits = try await store.recall(matching: "physics prac", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.category == "school")
    }

    @Test func recallRanksByTermOverlap() async throws {
        let store = InMemoryStore()
        try await store.remember(Fact(text: "swift concurrency notes", category: "dev"))
        try await store.remember(Fact(text: "swift ui layout and swift concurrency", category: "dev"))

        let hits = try await store.recall(matching: "swift concurrency", limit: 10)
        #expect(hits.first?.text == "swift ui layout and swift concurrency")
    }

    @Test func forgetRemovesFact() async throws {
        let store = InMemoryStore()
        let fact = Fact(text: "temporary", category: "misc")
        try await store.remember(fact)
        try await store.forget(id: fact.id)
        #expect(try await store.allFacts().isEmpty)
    }

    @Test func emptyQueryReturnsNothing() async throws {
        let store = InMemoryStore()
        try await store.remember(Fact(text: "anything", category: "misc"))
        #expect(try await store.recall(matching: "   ", limit: 10).isEmpty)
    }
}
