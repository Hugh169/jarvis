import Foundation
import Testing
import JarvisTools
@testable import JarvisMemory

@Suite("Memory tools")
struct MemoryToolsTests {
    private func store() throws -> SQLiteMemoryStore {
        try SQLiteMemoryStore(url: nil)
    }

    @Test("Remembering then recalling returns the fact")
    func roundTrip() async throws {
        let store = try store()
        _ = try await RememberTool(store: store).execute(
            ["text": "Bin night is Tuesday", "category": "home"]
        )

        let result = try await RecallTool(store: store).execute(["query": "bin night"])
        #expect(result.isError == false)
        #expect(result.content.contains("Bin night is Tuesday"))
        #expect(result.content.contains("(home)"))
    }

    @Test("Category defaults rather than failing")
    func defaultsCategory() async throws {
        let store = try store()
        _ = try await RememberTool(store: store).execute(["text": "Likes flat whites"])

        let facts = try await store.allFacts()
        #expect(facts.first?.category == "general")
    }

    @Test("Empty or whitespace text is rejected, not stored")
    func rejectsEmptyText() async throws {
        let store = try store()
        for text in ["", "   ", "\n"] {
            let result = try await RememberTool(store: store).execute(["text": .string(text)])
            #expect(result.isError)
        }
        #expect(try await store.allFacts().isEmpty)
    }

    @Test("Recall reports nothing found without erroring")
    func recallMissIsNotAnError() async throws {
        let store = try store()
        let result = try await RecallTool(store: store).execute(["query": "submarines"])
        #expect(result.isError == false)
        #expect(result.content.contains("Nothing remembered"))
    }

    @Test("Recall clamps the limit into range")
    func clampsLimit() async throws {
        let store = try store()
        for index in 0..<25 {
            _ = try await RememberTool(store: store).execute(["text": .string("coffee \(index)")])
        }
        let result = try await RecallTool(store: store).execute(
            ["query": "coffee", "limit": 500]
        )
        #expect(result.content.split(separator: "\n").count == 20)
    }

    @Test("Forget removes the fact and names what it removed")
    func forgets() async throws {
        let store = try store()
        _ = try await RememberTool(store: store).execute(["text": "Temporary thought"])
        let id = try #require(try await store.allFacts().first?.id)

        let result = try await ForgetTool(store: store).execute(["id": .string(id.uuidString)])
        #expect(result.isError == false)
        #expect(result.content.contains("Temporary thought"))
        #expect(try await store.allFacts().isEmpty)
    }

    /// Deleting nothing must not be reported as a deletion — the storage layer
    /// treats an unknown id as a no-op, so the tool has to check.
    @Test("Forgetting an unknown id is an error, not a false success")
    func forgetUnknownIsAnError() async throws {
        let store = try store()
        let result = try await ForgetTool(store: store).execute(
            ["id": .string(UUID().uuidString)]
        )
        #expect(result.isError)
    }

    @Test("Forget rejects anything that isn't a uuid")
    func forgetRejectsGarbageIds() async throws {
        let store = try store()
        for id in ["", "abc", "1"] {
            let result = try await ForgetTool(store: store).execute(["id": .string(id)])
            #expect(result.isError)
        }
    }

    /// The whole reason `forget` goes through the confirmation window.
    @Test("Only forget requires confirmation")
    func onlyForgetIsGated() {
        #expect(ForgetTool.requiresConfirmation)
        #expect(RememberTool.requiresConfirmation == false)
        #expect(RecallTool.requiresConfirmation == false)
    }

    @Test("Tools report unavailable memory instead of crashing")
    func handlesUnavailableStore() async throws {
        let result = try await RememberTool(store: nil).execute(["text": "anything"])
        #expect(result.isError)
        #expect(result.content.contains("unavailable"))
    }
}
