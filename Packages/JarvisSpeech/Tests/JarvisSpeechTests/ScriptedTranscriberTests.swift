import Testing
@testable import JarvisSpeech

@Suite struct ScriptedTranscriberTests {
    @Test func replaysPartialsAndFinal() async throws {
        let transcriber = ScriptedTranscriber(
            partials: ["what", "what's the", "what's the weather"],
            final: "What's the weather tomorrow?"
        )
        try await transcriber.start()
        let final = try await transcriber.finish()
        #expect(final == "What's the weather tomorrow?")

        var collected: [String] = []
        for await partial in transcriber.partials {
            collected.append(partial)
        }
        #expect(collected == ["what", "what's the", "what's the weather"])
    }
}
