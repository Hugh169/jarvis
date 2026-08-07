import Foundation
import JarvisTools

/// Gmail over the REST API, against the connected account.
///
/// Mail is the canonical untrusted input: anyone can send you some, and its
/// contents flow straight into a model that can run tools on this machine. So
/// nothing here acts on what it reads, `send_mail` is gated behind the
/// confirmation prompt, and the system prompt states that tool output is data
/// rather than instructions.
enum Gmail {
    static let base = "/gmail/v1/users/me"

    struct Message: Decodable {
        struct Payload: Decodable {
            struct Header: Decodable {
                let name: String
                let value: String
            }
            struct Part: Decodable {
                let mimeType: String?
                let body: Body?
                let parts: [Part]?
            }
            struct Body: Decodable {
                let data: String?
            }
            let headers: [Header]?
            let mimeType: String?
            let body: Body?
            let parts: [Part]?
        }
        let id: String?
        let snippet: String?
        let payload: Payload?
    }

    static func header(_ name: String, in message: Message) -> String? {
        message.payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    /// Gmail encodes bodies base64url, without padding.
    static func decode(_ encoded: String) -> String? {
        var text = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if text.count % 4 != 0 { text += String(repeating: "=", count: 4 - text.count % 4) }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Walks the MIME tree for the plain-text body. A multipart/alternative
    /// message carries both text and HTML; the text part is what should be
    /// read aloud, and the HTML part is mostly markup.
    static func plainText(_ payload: Message.Payload?) -> String? {
        guard let payload else { return nil }
        if payload.mimeType == "text/plain", let data = payload.body?.data {
            return decode(data)
        }
        return payload.parts.flatMap(firstPlainText)
    }

    private static func firstPlainText(_ parts: [Message.Payload.Part]) -> String? {
        for part in parts {
            if part.mimeType == "text/plain", let data = part.body?.data, let text = decode(data) {
                return text
            }
            if let nested = part.parts, let text = firstPlainText(nested) { return text }
        }
        return nil
    }

    /// RFC 2822, base64url encoded — the shape Gmail's send and draft
    /// endpoints take.
    static func rawMessage(to: String, subject: String, body: String) -> String {
        let message = """
            To: \(to)\r
            Subject: \(subject)\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            \(body)
            """
        return OAuthFlow.base64URL(Data(message.utf8))
    }
}

public struct SearchMailTool: JarvisTool {
    public static let name = "search_mail"
    public static let description = """
        Searches the connected Gmail account. Takes Gmail search syntax — \
        "from:sam is:unread", "subject:invoice newer_than:7d". Returns senders, \
        subjects and a one-line preview, not full messages; use read_mail for \
        the body of one.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Gmail search query."],
            "limit": ["type": "integer", "description": "How many, 1 to 20. Default 8."],
        ],
        "required": ["query"],
    ]

    private let account: GoogleAccount

    public init(account: GoogleAccount = .shared) {
        self.account = account
    }

    private struct ListResponse: Decodable {
        struct Reference: Decodable { let id: String }
        let messages: [Reference]?
    }

    /// Named rather than a tuple: the region-based isolation checker can't
    /// reason about destructuring one out of a task group.
    private struct Summary: Sendable {
        let index: Int
        let line: String
    }

    /// One message's headers. A failure here is reported in place rather than
    /// thrown, so a single unreadable message doesn't lose the whole search.
    private func summarise(_ id: String, index: Int) async -> Summary {
        do {
            let data = try await account.send(
                "\(Gmail.base)/messages/\(id)",
                query: [
                    .init(name: "format", value: "metadata"),
                    .init(name: "metadataHeaders", value: "From"),
                    .init(name: "metadataHeaders", value: "Subject"),
                    .init(name: "metadataHeaders", value: "Date"),
                ]
            )
            let message = try JSONDecoder().decode(Gmail.Message.self, from: data)
            let from = Gmail.header("From", in: message) ?? "unknown sender"
            let subject = Gmail.header("Subject", in: message) ?? "(no subject)"
            let preview = message.snippet.map { " — \($0.prefix(120))" } ?? ""
            return Summary(index: index, line: "[\(id)] \(from): \(subject)\(preview)")
        } catch {
            return Summary(index: index, line: "[\(id)] (couldn't be read: \(error.localizedDescription))")
        }
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let query = input["query"]?.stringValue, !query.isEmpty else {
            return .error("No search query given.")
        }
        let limit = max(1, min(20, Int(input["limit"]?.numberValue ?? 8)))

        let listing = try await account.send(
            "\(Gmail.base)/messages",
            query: [
                .init(name: "q", value: query),
                .init(name: "maxResults", value: String(limit)),
            ]
        )
        let references = try JSONDecoder().decode(ListResponse.self, from: listing).messages ?? []
        guard !references.isEmpty else {
            return ToolResult(content: "No mail matching \"\(query)\".")
        }

        // Gmail's list endpoint returns ids only, so each message costs a
        // second round trip and this is the slow part of the tool.
        //
        // Fetching them concurrently through a task group measured *worse* —
        // same three messages, 7.1s serially against 15.9s in a group. The
        // cause was a blocking Keychain read inside `GoogleAccount` on every
        // request, so the extra concurrency only piled up behind it; that read
        // is now cached. Sequential until a measurement says otherwise.
        var lines: [String] = []
        for (index, reference) in references.enumerated() {
            lines.append(await summarise(reference.id, index: index).line)
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}

public struct ReadMailTool: JarvisTool {
    public static let name = "read_mail"
    public static let description = """
        The full text of one message, by the id search_mail returned. Summarise \
        it in a sentence or two aloud and send anything longer to display_detail.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": ["type": "string", "description": "Message id from search_mail."],
        ],
        "required": ["id"],
    ]

    private let account: GoogleAccount

    public init(account: GoogleAccount = .shared) {
        self.account = account
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let id = input["id"]?.stringValue, !id.isEmpty else {
            return .error("No message id given.")
        }
        let data = try await account.send(
            "\(Gmail.base)/messages/\(id)",
            query: [.init(name: "format", value: "full")]
        )
        let message = try JSONDecoder().decode(Gmail.Message.self, from: data)

        let body = Gmail.plainText(message.payload)
            ?? message.snippet
            ?? "(no readable text — probably HTML only)"
        let lines = [
            "From: \(Gmail.header("From", in: message) ?? "unknown")",
            "Subject: \(Gmail.header("Subject", in: message) ?? "(none)")",
            "Date: \(Gmail.header("Date", in: message) ?? "unknown")",
            "",
            String(body.prefix(4000)),
        ]
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}

public struct DraftMailTool: JarvisTool {
    public static let name = "draft_mail"
    public static let description = """
        Saves a draft in Gmail without sending it. Prefer this over send_mail \
        unless the user clearly asked for it to go out now.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "to": ["type": "string", "description": "Recipient address."],
            "subject": ["type": "string", "description": "Subject line."],
            "body": ["type": "string", "description": "Message text."],
        ],
        "required": ["to", "subject", "body"],
    ]

    private let account: GoogleAccount

    public init(account: GoogleAccount = .shared) {
        self.account = account
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let to = input["to"]?.stringValue,
              let subject = input["subject"]?.stringValue,
              let body = input["body"]?.stringValue else {
            return .error("A recipient, subject and body are all required.")
        }
        let payload = JSONValue.object([
            "message": .object(["raw": .string(Gmail.rawMessage(to: to, subject: subject, body: body))])
        ])
        _ = try await account.send(
            "\(Gmail.base)/drafts", method: "POST", body: try JSONEncoder().encode(payload)
        )
        return ToolResult(content: "Saved a draft to \(to).")
    }
}

public struct SendMailTool: JarvisTool {
    public static let name = "send_mail"
    public static let description = """
        Sends an email from the connected Gmail account. This goes out \
        immediately and cannot be recalled.
        """
    /// Outward-facing and irreversible — the one tool here that must not run
    /// without the user saying yes.
    public static let requiresConfirmation = true
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "to": ["type": "string", "description": "Recipient address."],
            "subject": ["type": "string", "description": "Subject line."],
            "body": ["type": "string", "description": "Message text."],
        ],
        "required": ["to", "subject", "body"],
    ]

    private let account: GoogleAccount

    public init(account: GoogleAccount = .shared) {
        self.account = account
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let to = input["to"]?.stringValue,
              let subject = input["subject"]?.stringValue,
              let body = input["body"]?.stringValue else {
            return .error("A recipient, subject and body are all required.")
        }
        let payload = JSONValue.object([
            "raw": .string(Gmail.rawMessage(to: to, subject: subject, body: body))
        ])
        _ = try await account.send(
            "\(Gmail.base)/messages/send", method: "POST", body: try JSONEncoder().encode(payload)
        )
        return ToolResult(content: "Sent to \(to).")
    }
}
