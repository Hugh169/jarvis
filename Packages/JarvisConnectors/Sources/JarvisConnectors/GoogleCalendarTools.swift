import Foundation
import JarvisTools

/// Google Calendar over the REST API, against the connected account.
///
/// Deliberately separate from the EventKit calendar tools rather than replacing
/// them: EventKit reads whatever macOS has synced locally, this reads Google
/// directly. Both can be present, and the model picks by name.
public struct ListGoogleEventsTool: JarvisTool {
    public static let name = "list_google_events"
    public static let description = """
        Events from the connected Google Calendar over the next few days. Use \
        this for the user's Google calendar specifically; use list_events for \
        calendars macOS already knows about.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "days": ["type": "integer", "description": "How many days ahead, 1 to 30. Default 7."],
            "query": ["type": "string", "description": "Optional free-text filter."],
        ],
    ]

    private let account: GoogleAccount

    public init(account: GoogleAccount = .shared) {
        self.account = account
    }

    struct Response: Decodable {
        struct Item: Decodable {
            struct When: Decodable {
                let dateTime: String?
                let date: String?
            }
            let summary: String?
            let location: String?
            let start: When?
            let end: When?
        }
        let items: [Item]?
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        let days = max(1, min(30, Int(input["days"]?.numberValue ?? 7)))
        let now = Date.now
        var query: [URLQueryItem] = [
            .init(name: "timeMin", value: ISO8601DateFormatter().string(from: now)),
            .init(name: "timeMax", value: ISO8601DateFormatter().string(
                from: now.addingTimeInterval(Double(days) * 86_400)
            )),
            // Expands recurring events into occurrences; without it a weekly
            // meeting appears once, at its original start date.
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "50"),
        ]
        if let text = input["query"]?.stringValue, !text.isEmpty {
            query.append(.init(name: "q", value: text))
        }

        let data = try await account.send("/calendar/v3/calendars/primary/events", query: query)
        let items = try JSONDecoder().decode(Response.self, from: data).items ?? []
        guard !items.isEmpty else {
            return ToolResult(content: "Nothing in the next \(days) days.")
        }

        let lines = items.map { item -> String in
            let title = item.summary ?? "(no title)"
            let when = Self.describe(item.start)
            let place = item.location.map { " at \($0)" } ?? ""
            return "\(when): \(title)\(place)"
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }

    /// All-day events carry `date` instead of `dateTime`, and rendering one
    /// through a time formatter shows a spurious midnight.
    static func describe(_ when: Response.Item.When?) -> String {
        if let stamp = when?.dateTime, let date = ISO8601DateFormatter().date(from: stamp) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        if let day = when?.date { return "\(day) (all day)" }
        return "Unscheduled"
    }
}

public struct CreateGoogleEventTool: JarvisTool {
    public static let name = "create_google_event"
    public static let description = """
        Creates an event in the connected Google Calendar. Times are ISO 8601 \
        with an offset, e.g. 2026-08-09T16:00:00+10:00.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Event title."],
            "start": ["type": "string", "description": "Start, ISO 8601 with offset."],
            "end": ["type": "string", "description": "End, ISO 8601 with offset."],
            "location": ["type": "string", "description": "Optional location."],
            "notes": ["type": "string", "description": "Optional description."],
        ],
        "required": ["title", "start", "end"],
    ]

    private let account: GoogleAccount

    public init(account: GoogleAccount = .shared) {
        self.account = account
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let title = input["title"]?.stringValue,
              let start = input["start"]?.stringValue,
              let end = input["end"]?.stringValue else {
            return .error("A title, start and end are all required.")
        }

        var event: [String: JSONValue] = [
            "summary": .string(title),
            "start": .object(["dateTime": .string(start)]),
            "end": .object(["dateTime": .string(end)]),
        ]
        if let location = input["location"]?.stringValue { event["location"] = .string(location) }
        if let notes = input["notes"]?.stringValue { event["description"] = .string(notes) }

        let body = try JSONEncoder().encode(JSONValue.object(event))
        _ = try await account.send(
            "/calendar/v3/calendars/primary/events", method: "POST", body: body
        )
        return ToolResult(content: "Added \"\(title)\" to your Google calendar.")
    }
}
