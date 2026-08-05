import Testing
import Foundation
@testable import JarvisBrain

@Suite struct RequestEncodingTests {
    @Test func encodesSnakeCaseAndCacheControl() throws {
        let request = Anthropic.MessagesRequest(
            model: ModelTier.standard.modelID,
            maxTokens: 4096,
            system: [.init(text: "You are JARVIS.", cached: true)],
            messages: [.user("Hello")]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)

        #expect(json.contains("\"max_tokens\":4096"))
        #expect(json.contains("\"cache_control\":{\"type\":\"ephemeral\"}"))
        #expect(json.contains("\"model\":\"claude-sonnet-5\""))
        #expect(json.contains("\"stream\":true"))
        #expect(!json.contains("tools")) // nil fields must be omitted, not null
    }

    @Test func modelTierIDs() {
        #expect(ModelTier.fast.modelID == "claude-haiku-4-5")
        #expect(ModelTier.standard.modelID == "claude-sonnet-5")
        #expect(ModelTier.deep.modelID == "claude-opus-5")
    }
}
