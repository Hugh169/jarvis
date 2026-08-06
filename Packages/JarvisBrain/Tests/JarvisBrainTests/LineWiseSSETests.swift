import Testing
import Foundation
@testable import JarvisBrain

/// Regression tests for the way `AnthropicClient` drives `SSEParser`.
///
/// `URLSession.AsyncBytes.lines` drops blank lines, which are what dispatch an
/// SSE event. The client restores that boundary after each `data:` line; if
/// that ever regresses, a streamed turn silently yields zero text — the model
/// answers correctly and nothing is ever spoken.
@Suite struct LineWiseSSETests {
    /// Mirrors the client's feeding strategy.
    private func events(fromLines lines: [String]) -> [ServerSentEvent] {
        var parser = SSEParser()
        var collected: [ServerSentEvent] = []
        for line in lines {
            collected += parser.feed(line + "\n")
            if line.hasPrefix("data:") {
                collected += parser.feed("\n")
            }
        }
        return collected
    }

    @Test func extractsTextWhenBlankLinesAreMissing() throws {
        // Exactly what the API sends, minus the blank separators.
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start"}"#,
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Evening, sir."}}"#,
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ]

        let decoder = JSONDecoder()
        var text = ""
        var stopReason: String?

        for event in events(fromLines: lines) {
            let decoded = try decoder.decode(
                Anthropic.StreamEvent.self,
                from: Data(event.data.utf8)
            )
            if decoded.type == "content_block_delta", let delta = decoded.delta?.text {
                text += delta
            }
            if decoded.type == "message_delta" { stopReason = decoded.delta?.stopReason }
        }

        #expect(text == "Evening, sir.")
        #expect(stopReason == "end_turn")
    }

    @Test func eventNameSurvivesTheReconstructedBoundary() {
        let collected = events(fromLines: ["event: ping", #"data: {"type": "ping"}"#])
        #expect(collected.count == 1)
        #expect(collected.first?.event == "ping")
    }

    @Test func multipleDeltasAccumulateInOrder() throws {
        var lines: [String] = []
        for fragment in ["Good ", "evening, ", "sir."] {
            lines.append("event: content_block_delta")
            lines.append(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"\#(fragment)"}}"#)
        }

        let decoder = JSONDecoder()
        let text = try events(fromLines: lines).reduce(into: "") { result, event in
            let decoded = try decoder.decode(Anthropic.StreamEvent.self, from: Data(event.data.utf8))
            result += decoded.delta?.text ?? ""
        }
        #expect(text == "Good evening, sir.")
    }
}
