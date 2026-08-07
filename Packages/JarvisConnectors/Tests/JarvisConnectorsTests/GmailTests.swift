import Testing
import Foundation
@testable import JarvisConnectors

@Suite struct GmailTests {
    /// Gmail encodes bodies base64**url** without padding. Feeding that to a
    /// standard base64 decoder returns nil, and the message silently reads as
    /// "no readable text".
    @Test func decodesBase64URLWithoutPadding() {
        // "Hello, world!?~" contains bytes that encode to both - and _.
        let encoded = OAuthFlow.base64URL(Data("Hello, world!?~".utf8))
        #expect(!encoded.contains("="))
        #expect(Gmail.decode(encoded) == "Hello, world!?~")
    }

    @Test func decodesEachPaddingLength() {
        for text in ["a", "ab", "abc", "abcd"] {
            let encoded = OAuthFlow.base64URL(Data(text.utf8))
            #expect(Gmail.decode(encoded) == text, "round trip failed for \(text)")
        }
    }

    @Test func headerLookupIsCaseInsensitive() throws {
        let message = try decodeMessage(#"""
            {"id":"m1","payload":{"headers":[
              {"name":"from","value":"Sam <sam@example.com>"},
              {"name":"Subject","value":"Invoice"}]}}
            """#)
        #expect(Gmail.header("From", in: message) == "Sam <sam@example.com>")
        #expect(Gmail.header("subject", in: message) == "Invoice")
        #expect(Gmail.header("Bcc", in: message) == nil)
    }

    /// A simple message carries its body at the top level.
    @Test func readsASinglePartBody() throws {
        let body = OAuthFlow.base64URL(Data("Running late.".utf8))
        let message = try decodeMessage(#"""
            {"id":"m2","payload":{"mimeType":"text/plain","body":{"data":"\#(body)"}}}
            """#)
        #expect(Gmail.plainText(message.payload) == "Running late.")
    }

    /// A real message is usually multipart/alternative with text *and* HTML.
    /// Taking the first part rather than the text one returns markup.
    @Test func prefersPlainTextOverHTML() throws {
        let text = OAuthFlow.base64URL(Data("the plain one".utf8))
        let html = OAuthFlow.base64URL(Data("<p>the html one</p>".utf8))
        let message = try decodeMessage(#"""
            {"id":"m3","payload":{"mimeType":"multipart/alternative","parts":[
              {"mimeType":"text/html","body":{"data":"\#(html)"}},
              {"mimeType":"text/plain","body":{"data":"\#(text)"}}]}}
            """#)
        #expect(Gmail.plainText(message.payload) == "the plain one")
    }

    /// Attachments nest the alternative one level deeper.
    @Test func findsTextNestedUnderMultipartMixed() throws {
        let text = OAuthFlow.base64URL(Data("nested body".utf8))
        let message = try decodeMessage(#"""
            {"id":"m4","payload":{"mimeType":"multipart/mixed","parts":[
              {"mimeType":"multipart/alternative","parts":[
                {"mimeType":"text/plain","body":{"data":"\#(text)"}}]},
              {"mimeType":"application/pdf","body":{}}]}}
            """#)
        #expect(Gmail.plainText(message.payload) == "nested body")
    }

    /// An HTML-only message has no text part; callers fall back to the snippet
    /// rather than showing nothing.
    @Test func htmlOnlyMessageYieldsNoPlainText() throws {
        let html = OAuthFlow.base64URL(Data("<p>hi</p>".utf8))
        let message = try decodeMessage(#"""
            {"id":"m5","payload":{"mimeType":"text/html","body":{"data":"\#(html)"}}}
            """#)
        #expect(Gmail.plainText(message.payload) == nil)
    }

    @Test func rawMessageIsDecodableRFC2822() throws {
        let raw = Gmail.rawMessage(to: "sam@example.com", subject: "Lunch", body: "One o'clock?")
        let decoded = try #require(Gmail.decode(raw))
        #expect(decoded.contains("To: sam@example.com"))
        #expect(decoded.contains("Subject: Lunch"))
        #expect(decoded.contains("charset=utf-8"))
        // Headers end with a blank line; without it the body becomes a header.
        #expect(decoded.contains("\r\n\r\n"))
        #expect(decoded.hasSuffix("One o'clock?"))
    }

    /// Sending is outward-facing and irreversible; drafting is not.
    @Test func onlySendingIsGated() {
        #expect(SendMailTool.requiresConfirmation)
        #expect(DraftMailTool.requiresConfirmation == false)
        #expect(SearchMailTool.requiresConfirmation == false)
        #expect(ReadMailTool.requiresConfirmation == false)
    }

    @Test func scopesAreLeastPrivilege() {
        // Nothing granting deletion, and no blanket mail scope.
        #expect(!GoogleAccount.scopes.contains { $0.hasSuffix("/mail.google.com") })
        #expect(!GoogleAccount.scopes.contains { $0.contains("gmail.modify") })
        #expect(GoogleAccount.scopes.contains("https://www.googleapis.com/auth/gmail.readonly"))
    }

    private func decodeMessage(_ json: String) throws -> Gmail.Message {
        try JSONDecoder().decode(Gmail.Message.self, from: Data(json.utf8))
    }
}
