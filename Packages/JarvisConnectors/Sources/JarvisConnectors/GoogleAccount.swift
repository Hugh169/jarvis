import Foundation
import JarvisCore

/// One connected Google account, owned by JARVIS alone.
///
/// The refresh token is the standing grant and lives in the Keychain; the
/// access token is short-lived and stays in memory, so it is never written to
/// disk at all. Nothing is registered with macOS Internet Accounts, and no
/// other app on this Mac can see or use the connection.
public actor GoogleAccount {
    public static let shared = GoogleAccount()

    /// Least privilege: read and write calendar events, read mail, and create
    /// drafts. Notably absent is any scope that lets a tool delete anything.
    ///
    /// `gmail.compose` covers sending as well as drafting — Google has no
    /// draft-only scope — so `send_mail` is gated in the tool layer instead.
    public static let scopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.compose",
    ]

    public enum AccountError: Error, LocalizedError, Equatable {
        case notConnected
        case http(status: Int, body: String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                "No Google account connected. Connect one in Settings, under Connectors."
            case .http(let status, let body):
                "Google returned \(status): \(body)"
            }
        }
    }

    private let keychain: KeychainStore
    private let session: URLSession

    private var accessToken: String?
    private var expiresAt: Date?
    /// Held after the first read so the Keychain is touched once per session
    /// rather than on every API call.
    ///
    /// `SecItemCopyMatching` blocks for as long as the "wants to use your
    /// confidential information" dialog is up, and it blocks *inside this
    /// actor* — so every queued request waits behind it. That is what made a
    /// three-message mail search take sixteen seconds, and why doing the
    /// fetches concurrently made it worse rather than better.
    private var refreshToken: String?

    public init(keychain: KeychainStore = KeychainStore(), session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    // MARK: Connection

    public var isConnected: Bool {
        ((try? keychain.get(.googleRefreshToken)) ?? nil)?.isEmpty == false
    }

    private func flow() throws -> OAuthFlow {
        guard let id = (try? keychain.get(.googleClientID)) ?? nil, !id.isEmpty,
              let secret = (try? keychain.get(.googleClientSecret)) ?? nil, !secret.isEmpty
        else { throw OAuthFlow.FlowError.notConfigured }
        return OAuthFlow(clientID: id, clientSecret: secret, session: session)
    }

    /// Runs the interactive consent flow and stores the resulting grant.
    public func connect(openBrowser: @escaping @Sendable (URL) -> Void) async throws {
        let tokens = try await flow().authorize(scopes: Self.scopes, openBrowser: openBrowser)
        guard let refresh = tokens.refreshToken else { throw OAuthFlow.FlowError.noRefreshToken }
        try keychain.set(refresh, for: .googleRefreshToken)
        refreshToken = refresh
        accessToken = tokens.accessToken
        expiresAt = tokens.expiresAt
    }

    /// Forgets the grant locally. It stays revocable at
    /// myaccount.google.com/permissions, which is the only place it can be
    /// revoked on Google's side.
    public func disconnect() throws {
        try keychain.delete(.googleRefreshToken)
        refreshToken = nil
        accessToken = nil
        expiresAt = nil
    }

    // MARK: Requests

    private func storedRefreshToken() async throws -> String {
        if let refreshToken { return refreshToken }
        // Off-main and off this actor's critical path: an approval dialog can
        // hold this for as long as the user takes to answer it.
        let stored = try? await keychain.value(for: .googleRefreshToken)
        guard let token = stored ?? nil, !token.isEmpty else {
            throw AccountError.notConnected
        }
        refreshToken = token
        return token
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, let expiresAt, expiresAt > .now { return accessToken }
        let tokens = try await flow().refresh(using: try await storedRefreshToken())
        accessToken = tokens.accessToken
        expiresAt = tokens.expiresAt
        return tokens.accessToken
    }

    /// A Google API call, refreshing the access token when it has expired and
    /// once more if Google rejects it anyway — clock skew and server-side
    /// revocation both show up as a 401 on a token we believed was live.
    public func send(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        do {
            return try await perform(path, method: method, query: query, body: body)
        } catch AccountError.http(401, _) {
            expiresAt = nil
            return try await perform(path, method: method, query: query, body: body)
        }
    }

    private func perform(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com" + path)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountError.http(status: 0, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AccountError.http(
                status: http.statusCode,
                body: String(decoding: data, as: UTF8.self).prefix(300).description
            )
        }
        return data
    }
}
