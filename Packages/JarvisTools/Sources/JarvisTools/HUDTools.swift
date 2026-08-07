import Foundation
import JarvisCore

/// Puts markdown on screen instead of reading it aloud — the second half of the
/// two-channel rule. Long or structured answers belong here; the spoken reply
/// stays one or two sentences.
public struct DisplayDetailTool: JarvisTool {
    public static let name = "display_detail"
    public static let description = """
        Show detail on screen rather than speaking it. Use for lists, tables, \
        code, numbers, or anything the user needs to read rather than hear. \
        Say a one-line summary aloud and put the substance here.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "markdown": ["type": "string", "description": "Content to display. Markdown."]
        ],
        "required": ["markdown"],
    ]

    private let present: @Sendable (String) async -> Void

    public init(present: @escaping @Sendable (String) async -> Void) {
        self.present = present
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let markdown = input["markdown"]?.stringValue, !markdown.isEmpty else {
            return .error("Nothing to display.")
        }
        await present(markdown)
        return ToolResult(content: "Displayed on screen. Don't read it aloud; summarise in one line.")
    }
}

/// Draws a day as a timeline instead of describing it.
///
/// `display_detail` can only ever produce words. Anything with a shape — a
/// schedule, a route, a sequence — reads far better as a picture, and the
/// assistant is the only thing that knows which is which. So this is a
/// separate tool rather than a rendering mode: the model chooses the form.
public struct DisplayScheduleTool: JarvisTool {
    public static let name = "display_schedule"
    public static let description = """
        Draw a day or a sequence of events as a timeline on screen — times, \
        what's on, where, and how long it takes to get between them. Prefer \
        this over display_detail whenever the answer is a schedule or an \
        itinerary. Say one sentence aloud about the shape of it; the timeline \
        carries the rest. Set clashes on anything that overlaps.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": [
                "type": "string",
                "description": "Heading, e.g. \"Tomorrow\" or \"Friday 8 August\".",
            ],
            "events": [
                "type": "array",
                "description": "In chronological order.",
                "items": [
                    "type": "object",
                    "properties": [
                        "time": [
                            "type": "string",
                            "description": "Formatted as it should read, e.g. \"7:00 am\".",
                        ],
                        "title": ["type": "string", "description": "What's on."],
                        "location": ["type": "string", "description": "Where, if it matters."],
                        "travel_minutes": [
                            "type": "integer",
                            "description": "Minutes to get here from the previous event.",
                        ],
                        "travel_mode": [
                            "type": "string",
                            "enum": ["driving", "walking", "transit", "cycling"],
                            "description": "How they're getting here.",
                        ],
                        "clashes": [
                            "type": "boolean",
                            "description": "True if this overlaps another event.",
                        ],
                    ],
                    "required": ["time", "title"],
                ],
            ],
        ],
        "required": ["title", "events"],
    ]

    private let present: @Sendable (Schedule) async -> Void

    public init(present: @escaping @Sendable (Schedule) async -> Void) {
        self.present = present
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let title = input["title"]?.stringValue, !title.isEmpty else {
            return .error("A title is required.")
        }
        guard case .array(let raw)? = input["events"], !raw.isEmpty else {
            return .error("No events to draw.")
        }

        let items = raw.compactMap { entry -> ScheduleItem? in
            guard let time = entry["time"]?.stringValue,
                  let name = entry["title"]?.stringValue else { return nil }
            return ScheduleItem(
                time: time,
                title: name,
                location: entry["location"]?.stringValue,
                travelMinutes: entry["travel_minutes"]?.numberValue.map { Int($0) },
                travelMode: TravelDepiction(loose: entry["travel_mode"]?.stringValue),
                clashes: entry["clashes"]?.boolValue ?? false
            )
        }
        guard !items.isEmpty else {
            return .error("None of the events had both a time and a title.")
        }

        await present(Schedule(title: title, items: items))
        let clashes = items.filter(\.clashes).count
        let note = clashes > 0 ? " \(clashes) marked as clashing." : ""
        return ToolResult(
            content: "Timeline drawn with \(items.count) events.\(note) "
                + "Don't read it out; say one sentence about the shape of the day."
        )
    }
}

/// Explicit yes/no in the HUD. Most gating happens automatically via
/// `requiresConfirmation`, but this lets the model ask before something the
/// schema can't know is risky.
public struct RequestConfirmationTool: JarvisTool {
    public static let name = "request_confirmation"
    public static let description = """
        Ask the user to approve an action before doing it. Returns whether they \
        agreed. Use before anything destructive or irreversible.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "summary": [
                "type": "string",
                "description": "Plain description of what will happen, e.g. \"Delete 12 files in Downloads\".",
            ],
            "verb": ["type": "string", "description": "Button label, e.g. Delete or Send. Default Confirm."],
        ],
        "required": ["summary"],
    ]

    private let ask: @Sendable (String, String) async -> Bool

    public init(ask: @escaping @Sendable (String, String) async -> Bool) {
        self.ask = ask
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let summary = input["summary"]?.stringValue, !summary.isEmpty else {
            return .error("Confirm what?")
        }
        let verb = input["verb"]?.stringValue ?? "Confirm"
        let approved = await ask(summary, verb)
        return ToolResult(
            content: approved
                ? "The user approved. Proceed."
                : "The user declined. Do not proceed; acknowledge briefly."
        )
    }
}
