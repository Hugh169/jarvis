import Testing
import Foundation
@testable import JarvisConnectors

@Suite struct OAuthFlowTests {
    private func flow() -> OAuthFlow {
        OAuthFlow(clientID: "client-123.apps.googleusercontent.com", clientSecret: "secret-abc")
    }

    // MARK: PKCE

    /// The one vector from RFC 7636 appendix B. Getting this wrong fails only
    /// at the token exchange, with a generic `invalid_grant`.
    @Test func challengeMatchesTheSpecVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(OAuthFlow.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIsUnreservedAndLongEnough() {
        let verifier = OAuthFlow.randomVerifier()
        #expect(verifier.count >= 43 && verifier.count <= 128)
        // base64url only — a "+", "/" or "=" here is rejected by Google.
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func verifiersDiffer() {
        #expect(OAuthFlow.randomVerifier() != OAuthFlow.randomVerifier())
    }

    // MARK: Authorization URL

    @Test func authorizationURLCarriesWhatGoogleNeeds() throws {
        let url = flow().authorizationURL(
            scopes: ["https://www.googleapis.com/auth/calendar.events", "openid"],
            redirect: "http://127.0.0.1:52111",
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }

        #expect(url.host == "accounts.google.com")
        #expect(value("response_type") == "code")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("redirect_uri") == "http://127.0.0.1:52111")
        // Space-separated, and URLComponents handles the escaping.
        #expect(value("scope") == "https://www.googleapis.com/auth/calendar.events openid")
        // Both are required, together, or no refresh token comes back and the
        // connection quietly dies an hour later.
        #expect(value("access_type") == "offline")
        #expect(value("prompt") == "consent")
    }

    // MARK: Form encoding

    @Test func formEncodingEscapesReservedCharacters() {
        let encoded = OAuthFlow.formEncode(["a": "x/y+z=", "b": "plain"])
        #expect(encoded == "a=x%2Fy%2Bz%3D&b=plain")
    }

    /// Sorted so the body is deterministic and a failing request can be
    /// compared against a known-good one.
    @Test func formEncodingIsStable() {
        #expect(OAuthFlow.formEncode(["z": "1", "a": "2"]) == "a=2&z=1")
    }

    // MARK: Redirect parsing

    @Test func parsesTheCodeOutOfTheRequestLine() throws {
        let request = "GET /?code=4/0AY0e-abc_123&scope=email HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(try LoopbackListener.parse(request).get() == "4/0AY0e-abc_123")
    }

    /// The user pressing "Cancel" on the consent screen is a redirect too.
    @Test func deniedConsentIsAnError() {
        let request = "GET /?error=access_denied HTTP/1.1\r\n\r\n"
        #expect(throws: OAuthFlow.FlowError.denied("access_denied")) {
            try LoopbackListener.parse(request).get()
        }
    }

    @Test func junkRequestIsAnErrorNotACrash() {
        #expect(throws: (any Error).self) { try LoopbackListener.parse("").get() }
        #expect(throws: (any Error).self) { try LoopbackListener.parse("GET / HTTP/1.1\r\n\r\n").get() }
    }

    // MARK: Listener

    /// Binds for real: proves it takes an ephemeral loopback port rather than
    /// a fixed one, which would collide with anything else already listening.
    @Test func listenerBindsToAnEphemeralPort() async throws {
        let listener = try await LoopbackListener.start()
        defer { listener.stop() }
        #expect(listener.port > 0)
    }

    /// The whole redirect leg, for real: bind, connect over TCP, send the
    /// request Google would send, and read the code back out. This is the part
    /// that can't be checked by inspection — the browser has to get a page back
    /// and the code has to reach the waiter.
    @Test func listenerCompletesTheRedirectRoundTrip() async throws {
        let listener = try await LoopbackListener.start()
        defer { listener.stop() }

        async let received = listener.awaitCode()

        let reply = try await Self.get(
            port: listener.port,
            target: "/?code=4%2F0AY0e-test&scope=email"
        )
        // The browser must land on something, not a dead socket.
        #expect(reply.contains("200 OK"))
        #expect(reply.contains("JARVIS is connected"))
        // Percent-encoding survives: Google's codes contain "/".
        #expect(try await received == "4/0AY0e-test")
    }

    @Test func listenerReportsADeniedConsent() async throws {
        let listener = try await LoopbackListener.start()
        defer { listener.stop() }

        let received = Task { try await listener.awaitCode() }
        _ = try await Self.get(port: listener.port, target: "/?error=access_denied")

        await #expect(throws: OAuthFlow.FlowError.denied("access_denied")) {
            try await received.value
        }
    }

    /// Minimal HTTP client — the point is to exercise the listener over a real
    /// socket rather than to call `parse` directly.
    private static func get(port: UInt16, target: String) async throws -> String {
        try await Task.detached {
            let client = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(client) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw TestFailure.connect(errno) }

            let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            _ = Array(request.utf8).withUnsafeBufferPointer {
                write(client, $0.baseAddress!, $0.count)
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { throw TestFailure.read(errno) }
            return String(decoding: buffer[0..<count], as: UTF8.self)
        }.value
    }

    private enum TestFailure: Error {
        case connect(Int32)
        case read(Int32)
    }
}
