import Foundation
import CryptoKit
import Network

/// The authorization-code flow with PKCE, against a loopback redirect.
///
/// This is the shape Google requires for a native app, and the reason the
/// connection can live entirely inside JARVIS rather than in macOS's Internet
/// Accounts: the app opens a browser, Google redirects back to a listener on
/// 127.0.0.1, and the code is exchanged for tokens here. Nothing is registered
/// with the system, and no other app can see the grant.
///
/// The out-of-band flow (`urn:ietf:wg:oauth:2.0:oob`, where the user copies a
/// code out of the browser) is not an option — Google removed it.
public struct OAuthFlow: Sendable {
    public struct Endpoints: Sendable {
        public let authorize: URL
        public let token: URL

        public init(authorize: URL, token: URL) {
            self.authorize = authorize
            self.token = token
        }

        public static let google = Endpoints(
            authorize: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            token: URL(string: "https://oauth2.googleapis.com/token")!
        )
    }

    public struct Tokens: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date

        public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }
    }

    public enum FlowError: Error, LocalizedError, Equatable {
        case notConfigured
        case listenerFailed(String)
        case cancelled
        case denied(String)
        case noRefreshToken
        case tokenExchangeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                "No Google client ID and secret — add them in Settings, under Connectors."
            case .listenerFailed(let reason):
                "Couldn't open a local port to finish signing in: \(reason)"
            case .cancelled:
                "Sign-in was cancelled."
            case .denied(let reason):
                "Google refused the sign-in: \(reason)"
            case .noRefreshToken:
                // Without `prompt=consent` Google reissues an access token and
                // no refresh token, which silently produces a connection that
                // dies in an hour and cannot be renewed.
                "Google didn't return a refresh token. Disconnect and connect again."
            case .tokenExchangeFailed(let reason):
                "Couldn't exchange the sign-in for a token: \(reason)"
            }
        }
    }

    let clientID: String
    let clientSecret: String
    let endpoints: Endpoints
    let session: URLSession

    public init(
        clientID: String,
        clientSecret: String,
        endpoints: Endpoints = .google,
        session: URLSession = .shared
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.endpoints = endpoints
        self.session = session
    }

    // MARK: Authorization

    /// Runs the full interactive flow and returns the tokens.
    ///
    /// `openBrowser` is injected rather than calling `NSWorkspace` directly so
    /// this package stays free of AppKit and the flow stays testable.
    public func authorize(
        scopes: [String],
        openBrowser: @Sendable (URL) -> Void
    ) async throws -> Tokens {
        let verifier = Self.randomVerifier()
        let listener = try await LoopbackListener.start()
        defer { listener.stop() }

        let redirect = "http://127.0.0.1:\(listener.port)"
        openBrowser(authorizationURL(scopes: scopes, redirect: redirect, verifier: verifier))

        let code = try await listener.awaitCode()
        return try await exchange(code: code, verifier: verifier, redirect: redirect)
    }

    func authorizationURL(scopes: [String], redirect: String, verifier: String) -> URL {
        var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            // Both are required to get a refresh token back. `offline` alone
            // returns one only on the very first consent ever given, so a
            // reconnect would come back without one.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    // MARK: Token exchange

    func exchange(code: String, verifier: String, redirect: String) async throws -> Tokens {
        try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
        ])
    }

    /// Trades a refresh token for a fresh access token. Google does not return
    /// a new refresh token here, so the stored one stays as it is.
    public func refresh(using refreshToken: String) async throws -> Tokens {
        try await requestTokens([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
    }

    private func requestTokens(_ fields: [String: String]) async throws -> Tokens {
        var form = fields
        form["client_id"] = clientID
        form["client_secret"] = clientSecret

        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FlowError.tokenExchangeFailed("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw FlowError.tokenExchangeFailed("HTTP \(http.statusCode): \(body.prefix(300))")
        }

        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Tokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            // A minute of slack so a request never goes out with a token that
            // expires while it is in flight.
            expiresAt: Date.now.addingTimeInterval((decoded.expires_in ?? 3600) - 60)
        )
    }

    // MARK: PKCE

    /// RFC 7636: 43–128 characters from the unreserved set.
    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }
}
