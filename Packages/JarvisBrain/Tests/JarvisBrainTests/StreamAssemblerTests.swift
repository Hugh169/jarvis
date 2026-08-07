import Testing
import Foundation
import JarvisTools
@testable import JarvisBrain

/// Drives the real assembler through the real SSE parser, using the byte
/// sequence the API actually sends. Server-side tools were the reason this got
/// pulled out of the client: their blocks have to come back out of the stream
/// exactly as they went in, and nothing about that is visible from the outside
/// until a turn silently loses its search results.
@Suite struct StreamAssemblerTests {
    /// Mirrors the client: feed each line, then restore the blank line that
    /// `AsyncBytes.lines` swallowed, since that is what dispatches an event.
    private func run(_ lines: [String]) -> [AnthropicClient.StreamEvent] {
        var parser = SSEParser()
        var assembler = StreamAssembler()
        let decoder = JSONDecoder()
        var produced: [AnthropicClient.StreamEvent] = []

        for line in lines {
            var events = parser.feed(line + "\n")
            if line.hasPrefix("data:") { events += parser.feed("\n") }
            for event in events {
                guard let decoded = try? decoder.decode(
                    Anthropic.StreamEvent.self, from: Data(event.data.utf8)
                ) else { continue }
                produced += assembler.accept(decoded)
            }
        }
        return produced
    }

    // MARK: Existing behaviour

    @Test func textAndToolUse() throws {
        let events = run([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Right away."}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Sy"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"dney\"}"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ])

        #expect(events.count == 3)
        #expect(events[0] == .text("Right away."))
        guard case .toolUse(let use) = events[1] else {
            Issue.record("expected a tool call, got \(events[1])")
            return
        }
        #expect(use.id == "toolu_1")
        #expect(use.name == "get_weather")
        #expect(use.input["city"]?.stringValue == "Sydney")
        #expect(events[2] == .finished(stopReason: "tool_use"))
    }

    /// A tool taking no arguments streams no `input_json_delta` at all.
    @Test func toolUseWithNoArguments() throws {
        let events = run([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_2","name":"clipboard_read","input":{}}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ])
        guard case .toolUse(let use) = try #require(events.first) else {
            Issue.record("expected a tool call")
            return
        }
        #expect(use.input == .object([:]))
    }

    // MARK: Server-side tools

    @Test func webSearchBlocksSurviveTheStream() throws {
        let events = run([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"today"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"s headlines\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"Budget handed down","url":"https://example.com/a"}]}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
        ])

        #expect(events.count == 2)

        guard case .serverBlock(let call) = events[0] else {
            Issue.record("expected the search call, got \(events[0])")
            return
        }
        #expect(call["type"]?.stringValue == "server_tool_use")
        #expect(call["id"]?.stringValue == "srvtoolu_1")
        // Merged back in from the streamed fragments — without this the block
        // goes back with an empty `input` and the model sees a call it never made.
        #expect(call["input"]?["query"]?.stringValue == "todays headlines")

        guard case .serverBlock(let result) = events[1] else {
            Issue.record("expected the search result, got \(events[1])")
            return
        }
        #expect(result["type"]?.stringValue == "web_search_tool_result")
        #expect(result["tool_use_id"]?.stringValue == "srvtoolu_1")
        #expect(result["content"]?[0]?["title"]?.stringValue == "Budget handed down")
    }

    /// A failed search is still a 200 and still a well-formed block: `content`
    /// comes back as a single error object rather than an array of results.
    /// Code that assumes an array reads that as a crash.
    @Test func searchFailureIsABlockNotAnError() throws {
        let events = run([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_9","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ])

        guard case .serverBlock(let block) = try #require(events.first) else {
            Issue.record("expected a server block")
            return
        }
        #expect(block["content"]?["error_code"]?.stringValue == "max_uses_exceeded")
        #expect(block["content"]?[0] == nil)
    }

    /// The server-side search loop has its own iteration cap; hitting it ends
    /// the turn `pause_turn`, which the pipeline resumes rather than treating
    /// as a finished answer.
    @Test func pauseTurnIsReportedAsAStopReason() {
        let events = run([
            #"data: {"type":"message_delta","delta":{"stop_reason":"pause_turn"}}"#,
        ])
        #expect(events == [.finished(stopReason: "pause_turn")])
    }

    /// Text can resume after a search, so the pipeline rebuilds the assistant
    /// turn in arrival order; the assembler must not reorder or coalesce.
    @Test func orderIsPreservedAcrossBlockTypes() {
        let events = run([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"One moment."}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"s1","name":"web_search","input":{}}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"The budget passed."}}"#,
            #"data: {"type":"content_block_stop","index":2}"#,
        ])

        #expect(events.count == 3)
        #expect(events[0] == .text("One moment."))
        if case .serverBlock = events[1] {} else { Issue.record("expected the search call second") }
        #expect(events[2] == .text("The budget passed."))
    }

    /// Unknown block types are the normal case for anything Anthropic adds
    /// server-side later; they must pass through rather than be dropped.
    @Test func unknownBlockTypesPassThrough() throws {
        let events = run([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"some_future_block","payload":42}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ])
        guard case .serverBlock(let block) = try #require(events.first) else {
            Issue.record("expected a passthrough block")
            return
        }
        #expect(block["payload"]?.numberValue == 42)
    }
}
