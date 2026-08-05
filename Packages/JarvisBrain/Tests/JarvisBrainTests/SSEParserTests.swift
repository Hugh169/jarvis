import Testing
import Foundation
@testable import JarvisBrain

@Suite struct SSEParserTests {
    @Test func parsesSingleEvent() {
        var parser = SSEParser()
        let events = parser.feed("event: message_start\ndata: {\"type\":\"message_start\"}\n\n")
        #expect(events == [ServerSentEvent(event: "message_start", data: "{\"type\":\"message_start\"}")])
    }

    @Test func handlesChunksSplitMidLine() {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []
        for chunk in ["event: content_block", "_delta\nda", "ta: {\"text\":\"Hi\"}\n", "\n"] {
            events += parser.feed(chunk)
        }
        #expect(events == [ServerSentEvent(event: "content_block_delta", data: "{\"text\":\"Hi\"}")])
    }

    @Test func multipleEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed("data: one\n\ndata: two\n\n")
        #expect(events.map(\.data) == ["one", "two"])
    }

    @Test func multiLineDataIsJoined() {
        var parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n")
        #expect(events == [ServerSentEvent(event: nil, data: "line1\nline2")])
    }

    @Test func commentsAndKeepAlivesIgnored() {
        var parser = SSEParser()
        let events = parser.feed(": ping\n\ndata: real\n\n")
        #expect(events == [ServerSentEvent(event: nil, data: "real")])
    }

    @Test func crlfLineEndings() {
        var parser = SSEParser()
        let events = parser.feed("event: e\r\ndata: d\r\n\r\n")
        #expect(events == [ServerSentEvent(event: "e", data: "d")])
    }

    /// A chunk may end between the CR and the LF. Swift treats CRLF as one
    /// grapheme cluster, so this is the case a String-level search gets wrong.
    @Test func crlfSplitAcrossChunkBoundary() {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []
        for chunk in ["data: split\r", "\n\r", "\n"] {
            events += parser.feed(chunk)
        }
        #expect(events == [ServerSentEvent(event: nil, data: "split")])
    }

    @Test func decodesAnthropicDeltaPayload() throws {
        var parser = SSEParser()
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        let events = parser.feed("event: content_block_delta\ndata: \(payload)\n\n")
        let event = try #require(events.first)
        let decoded = try JSONDecoder().decode(Anthropic.StreamEvent.self, from: Data(event.data.utf8))
        #expect(decoded.type == "content_block_delta")
        #expect(decoded.delta?.text == "Hello")
    }
}
