import Foundation

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
