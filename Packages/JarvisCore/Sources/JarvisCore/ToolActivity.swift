import Foundation

/// One tool invocation as the HUD shows it: which app is being driven, how long
/// it has been running, and how it ended.
public struct ToolActivity: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case running
        case awaitingConfirmation
        case succeeded
        case failed(String)

        public var isTerminal: Bool {
            switch self {
            case .succeeded, .failed: true
            case .running, .awaitingConfirmation: false
            }
        }
    }

    public let id: UUID
    /// Raw tool name, shown in monospace ("create_reminder").
    public let toolName: String
    /// Human phrasing, shown in the UI face ("Adding a reminder").
    public let title: String
    /// Bundle id of the app being driven, for the real icon. Nil for tools that
    /// aren't app-backed (web search, memory).
    public let bundleIdentifier: String?
    /// SF Symbol fallback when there is no app icon to show.
    public let symbolName: String
    public var status: Status
    public let startedAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        toolName: String,
        title: String,
        bundleIdentifier: String?,
        symbolName: String,
        status: Status = .running,
        startedAt: Date = .now,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.symbolName = symbolName
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Elapsed time: final once finished, live otherwise.
    public func elapsed(now: Date = .now) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Ordered log of the current turn's tool activity, keyed by id.
public struct ToolActivityLog: Sendable, Equatable {
    public private(set) var activities: [ToolActivity] = []

    public init() {}

    public var isEmpty: Bool { activities.isEmpty }

    /// True while any tool is still working — drives the "Working" indicator.
    public var hasRunning: Bool {
        activities.contains { !$0.status.isTerminal }
    }

    public mutating func begin(_ activity: ToolActivity) {
        activities.append(activity)
    }

    /// Marks an activity terminal. Ignores unknown ids and refuses to re-finish
    /// one that already ended, so a late duplicate result can't rewrite history.
    @discardableResult
    public mutating func finish(id: UUID, status: ToolActivity.Status, at date: Date = .now) -> Bool {
        guard status.isTerminal,
              let index = activities.firstIndex(where: { $0.id == id }),
              !activities[index].status.isTerminal
        else { return false }
        activities[index].status = status
        activities[index].finishedAt = date
        return true
    }

    public mutating func clear() {
        activities.removeAll()
    }
}

/// A destructive or outward-facing action waiting on a yes/no in the HUD.
public struct ConfirmationRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toolName: String
    /// What will happen, in plain words ("Send to Dad — \"Running late\"").
    public let summary: String
    public let bundleIdentifier: String?
    public let symbolName: String
    /// Verb for the approve button ("Send", "Delete", "Run").
    public let confirmVerb: String

    public init(
        id: UUID = UUID(),
        toolName: String,
        summary: String,
        bundleIdentifier: String? = nil,
        symbolName: String = "exclamationmark.shield",
        confirmVerb: String = "Confirm"
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.bundleIdentifier = bundleIdentifier
        self.symbolName = symbolName
        self.confirmVerb = confirmVerb
    }
}

/// Maps tool names to how they present in the HUD. Kept as pure data here so it
/// is testable without importing AppKit.
public enum ToolPresentation {
    public struct Descriptor: Sendable, Equatable {
        public let title: String
        public let bundleIdentifier: String?
        public let symbolName: String
    }

    private static let table: [String: Descriptor] = [
        "create_reminder": .init(title: "Adding a reminder", bundleIdentifier: "com.apple.reminders", symbolName: "checklist"),
        "list_reminders": .init(title: "Checking reminders", bundleIdentifier: "com.apple.reminders", symbolName: "checklist"),
        "complete_reminder": .init(title: "Ticking off a reminder", bundleIdentifier: "com.apple.reminders", symbolName: "checkmark.circle"),
        "create_event": .init(title: "Creating the event", bundleIdentifier: "com.apple.iCal", symbolName: "calendar.badge.plus"),
        "list_events": .init(title: "Checking your calendar", bundleIdentifier: "com.apple.iCal", symbolName: "calendar"),
        "find_free_time": .init(title: "Looking for a gap", bundleIdentifier: "com.apple.iCal", symbolName: "calendar.badge.clock"),
        "get_weather": .init(title: "Checking the forecast", bundleIdentifier: "com.apple.weather", symbolName: "cloud.sun"),
        "where_am_i": .init(title: "Working out where you are", bundleIdentifier: "com.apple.Maps", symbolName: "location"),
        "travel_time_to": .init(title: "Checking how long it takes", bundleIdentifier: "com.apple.Maps", symbolName: "car"),
        "directions_to": .init(title: "Working out the route", bundleIdentifier: "com.apple.Maps", symbolName: "arrow.triangle.turn.up.right.diamond"),
        "nearby": .init(title: "Looking for what's nearby", bundleIdentifier: "com.apple.Maps", symbolName: "mappin.and.ellipse"),
        "send_message": .init(title: "Sending a message", bundleIdentifier: "com.apple.MobileSMS", symbolName: "message"),
        "compose_mail": .init(title: "Composing mail", bundleIdentifier: "com.apple.mail", symbolName: "envelope"),
        "search_files": .init(title: "Searching your files", bundleIdentifier: "com.apple.finder", symbolName: "magnifyingglass"),
        "read_file": .init(title: "Reading a file", bundleIdentifier: "com.apple.finder", symbolName: "doc.text"),
        "write_file": .init(title: "Writing a file", bundleIdentifier: "com.apple.finder", symbolName: "square.and.pencil"),
        "run_shortcut": .init(title: "Running a shortcut", bundleIdentifier: "com.apple.shortcuts", symbolName: "bolt"),
        "run_shell": .init(title: "Running a command", bundleIdentifier: "com.apple.Terminal", symbolName: "terminal"),
        "run_applescript": .init(title: "Automating an app", bundleIdentifier: "com.apple.ScriptEditor2", symbolName: "scroll"),
        "open_url": .init(title: "Opening a link", bundleIdentifier: "com.apple.Safari", symbolName: "safari"),
        "web_search": .init(title: "Searching the web", bundleIdentifier: nil, symbolName: "globe"),
        "remember": .init(title: "Committing that to memory", bundleIdentifier: nil, symbolName: "brain"),
        "recall": .init(title: "Recalling what I know", bundleIdentifier: nil, symbolName: "brain"),
        "display_detail": .init(title: "Putting details on screen", bundleIdentifier: nil, symbolName: "rectangle.on.rectangle"),
    ]

    /// Falls back to a humanised form of the tool name so MCP and future tools
    /// still render sensibly without being listed here.
    public static func descriptor(for toolName: String) -> Descriptor {
        if let known = table[toolName] { return known }
        return Descriptor(
            title: humanise(toolName),
            bundleIdentifier: nil,
            symbolName: "wrench.and.screwdriver"
        )
    }

    /// "github__create_issue" -> "Create issue", "set_volume" -> "Set volume".
    static func humanise(_ toolName: String) -> String {
        let bare = toolName.components(separatedBy: "__").last ?? toolName
        let words = bare.split(separator: "_").map(String.init)
        guard let first = words.first else { return toolName }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }
}
