import Foundation
import JarvisCore
import EventKit

/// All EventKit work happens inside this actor.
///
/// `EKEventStore`, `EKReminder` and friends are not `Sendable`, so they must
/// never cross the isolation boundary — every method returns plain values and
/// the tools below are thin wrappers.
public actor EventKitAccess {
    public static let shared = EventKitAccess()

    private let store = EKEventStore()
    private var remindersGranted: Bool?
    private var calendarGranted: Bool?

    public enum AccessError: Error, LocalizedError {
        case remindersDenied
        case calendarDenied
        case noMatch(String)
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .remindersDenied: "Reminders access is off. Turn it on in System Settings."
            case .calendarDenied: "Calendar access is off. Turn it on in System Settings."
            case .noMatch(let what): "No match for \"\(what)\"."
            case .saveFailed(let reason): "Couldn't save: \(reason)"
            }
        }
    }

    private func ensureReminders() async throws {
        if remindersGranted == nil {
            remindersGranted = (try? await store.requestFullAccessToReminders()) ?? false
        }
        guard remindersGranted == true else { throw AccessError.remindersDenied }
    }

    private func ensureCalendar() async throws {
        if calendarGranted == nil {
            calendarGranted = (try? await store.requestFullAccessToEvents()) ?? false
        }
        guard calendarGranted == true else { throw AccessError.calendarDenied }
    }

    /// `EKReminder` is not `Sendable`, but the continuation hands the array
    /// back into this actor and it never leaves. The box states that.
    private struct ReminderBox: @unchecked Sendable {
        let reminders: [EKReminder]
    }

    /// The Reminders fetch is callback-based; bridged once, inside the actor.
    private func fetchIncomplete() async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        let box: ReminderBox = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: ReminderBox(reminders: reminders ?? []))
            }
        }
        return box.reminders
    }

    // MARK: Reminders

    public func createReminder(title: String, due: Date?, notes: String?) async throws -> String {
        try await ensureReminders()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()

        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw AccessError.saveFailed(error.localizedDescription)
        }
        guard let due else { return "Created reminder \"\(title)\"." }
        return "Created reminder \"\(title)\" for \(due.formatted(date: .abbreviated, time: .shortened))."
    }

    public func listReminders(limit: Int) async throws -> [String] {
        try await ensureReminders()
        let reminders = await fetchIncomplete()
        return reminders
            .sorted {
                ($0.dueDateComponents?.date ?? .distantFuture)
                    < ($1.dueDateComponents?.date ?? .distantFuture)
            }
            .prefix(limit)
            .map { reminder in
                let title = reminder.title ?? "Untitled"
                guard let due = reminder.dueDateComponents?.date else { return "- \(title)" }
                return "- \(title) (due \(due.formatted(date: .abbreviated, time: .shortened)))"
            }
    }

    public func completeReminder(matching query: String) async throws -> String {
        try await ensureReminders()
        let reminders = await fetchIncomplete()
        guard let match = reminders.first(where: {
            ($0.title ?? "").lowercased().contains(query.lowercased())
        }) else {
            throw AccessError.noMatch(query)
        }
        let title = match.title ?? query
        match.isCompleted = true
        do {
            try store.save(match, commit: true)
        } catch {
            throw AccessError.saveFailed(error.localizedDescription)
        }
        return "Completed \"\(title)\"."
    }

    // MARK: Calendar

    public func createEvent(
        title: String, start: Date, end: Date, location: String?, notes: String?
    ) async throws -> String {
        try await ensureCalendar()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw AccessError.saveFailed(error.localizedDescription)
        }
        return "Created \"\(title)\" on \(start.formatted(date: .abbreviated, time: .shortened))."
    }

    /// Structured rather than pre-formatted, so the same lookup can feed both
    /// the model's text and the HUD's timeline without either re-parsing the
    /// other's prose.
    public func listEvents(start: Date, days: Double) async throws -> [CalendarEvent] {
        try await ensureCalendar()
        let predicate = store.predicateForEvents(
            withStart: start, end: start.addingTimeInterval(days * 86400), calendars: nil
        )
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                CalendarEvent(
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    end: $0.endDate,
                    isAllDay: $0.isAllDay,
                    location: $0.location?.isEmpty == false ? $0.location : nil
                )
            }
    }
}

// MARK: - Reminder tools

public struct CreateReminderTool: JarvisTool {
    public static let name = "create_reminder"
    public static let description = """
        Create a reminder in the Reminders app. Use for tasks and to-dos. \
        Give due_date in ISO 8601 with the local offset when the user names a time.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "What to be reminded of."],
            "due_date": [
                "type": "string",
                "description": "ISO 8601 date-time, e.g. 2026-08-07T16:00:00+10:00. Omit for no due date.",
            ],
            "notes": ["type": "string", "description": "Optional extra detail."],
        ],
        "required": ["title"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let title = input["title"]?.stringValue, !title.isEmpty else {
            return .error("A reminder needs a title.")
        }
        let due = input["due_date"]?.stringValue.flatMap(ISO8601.date(from:))
        do {
            let message = try await EventKitAccess.shared.createReminder(
                title: title, due: due, notes: input["notes"]?.stringValue
            )
            return ToolResult(content: message)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct ListRemindersTool: JarvisTool {
    public static let name = "list_reminders"
    public static let description = "List incomplete reminders, soonest first."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["limit": ["type": "integer", "description": "Maximum to return. Default 10."]],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        let limit = Int(input["limit"]?.numberValue ?? 10)
        do {
            let lines = try await EventKitAccess.shared.listReminders(limit: limit)
            return ToolResult(content: lines.isEmpty ? "No outstanding reminders." : lines.joined(separator: "\n"))
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct CompleteReminderTool: JarvisTool {
    public static let name = "complete_reminder"
    public static let description = "Mark a reminder complete by matching its title."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["title": ["type": "string", "description": "Title, or a distinctive part of it."]],
        "required": ["title"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let query = input["title"]?.stringValue, !query.isEmpty else {
            return .error("Which reminder?")
        }
        do {
            return ToolResult(content: try await EventKitAccess.shared.completeReminder(matching: query))
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

// MARK: - Calendar tools

public struct CreateEventTool: JarvisTool {
    public static let name = "create_event"
    public static let description = "Create a calendar event."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "start": ["type": "string", "description": "ISO 8601 start, with local offset."],
            "end": ["type": "string", "description": "ISO 8601 end. Defaults to one hour after start."],
            "location": ["type": "string"],
            "notes": ["type": "string"],
        ],
        "required": ["title", "start"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let title = input["title"]?.stringValue,
              let startRaw = input["start"]?.stringValue,
              let start = ISO8601.date(from: startRaw)
        else {
            return .error("An event needs a title and a start time.")
        }
        let end = input["end"]?.stringValue.flatMap(ISO8601.date(from:))
            ?? start.addingTimeInterval(3600)
        do {
            let message = try await EventKitAccess.shared.createEvent(
                title: title,
                start: start,
                end: end,
                location: input["location"]?.stringValue,
                notes: input["notes"]?.stringValue
            )
            return ToolResult(content: message)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// One event, as the calendar has it.
public struct CalendarEvent: Sendable, Hashable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?

    public init(title: String, start: Date, end: Date, isAllDay: Bool, location: String?) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
    }

    /// How the time should be said, which is not how it should be sorted.
    var spokenTime: String {
        isAllDay ? "all day" : start.formatted(date: .omitted, time: .shortened)
    }
}

public struct ListEventsTool: JarvisTool {
    public static let name = "list_events"
    public static let description = "List calendar events in a window. Defaults to the next 24 hours."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "start": ["type": "string", "description": "ISO 8601 start of the window. Defaults to now."],
            "days": ["type": "number", "description": "Window length in days. Default 1."],
        ],
    ]

    /// Draws what was found, without waiting to be asked.
    ///
    /// `display_schedule` exists and the model still would not call it — not
    /// with a system prompt rule, not with the trigger spelled out in the
    /// tool's own description, not with an instruction attached to this tool's
    /// result. Three layers of asking, ignored, and the day read out loud
    /// item by item every time.
    ///
    /// So it stops being a decision. If the calendar was consulted, the
    /// timeline is drawn — the model's only job is to say something useful
    /// about it. The model may still call `display_schedule` itself to add
    /// travel legs, which replaces this.
    private let present: (@Sendable (Schedule) async -> Void)?

    public init(present: (@Sendable (Schedule) async -> Void)? = nil) {
        self.present = present
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        let start = input["start"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
        let days = input["days"]?.numberValue ?? 1
        do {
            let events = try await EventKitAccess.shared.listEvents(start: start, days: days)
            guard !events.isEmpty else {
                return ToolResult(content: "Nothing in the calendar for that period.")
            }

            await present?(Self.schedule(for: events, from: start, days: days))

            let lines = events.map { "- \($0.title) (\($0.spokenTime))" }
            return ToolResult(
                content: lines.joined(separator: "\n") + """


                    These are already on screen as a timeline. Don't read them \
                    out — say one sentence about the shape of the day.
                    """
            )
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static func schedule(for events: [CalendarEvent], from start: Date, days: Double) -> Schedule {
        let clashing = overlapping(events)
        return Schedule(
            title: title(from: start, days: days),
            items: events.map { event in
                ScheduleItem(
                    time: event.spokenTime,
                    title: event.title,
                    location: event.location,
                    clashes: clashing.contains(event)
                )
            }
        )
    }

    /// Computed here rather than asked of the model: it has the start and end
    /// of everything, so whether two things overlap is arithmetic, not
    /// judgement. All-day events are excluded — they overlap everything by
    /// definition and flagging them would make the whole day amber.
    static func overlapping(_ events: [CalendarEvent]) -> Set<CalendarEvent> {
        var clashing: Set<CalendarEvent> = []
        let timed = events.filter { !$0.isAllDay }
        for (index, event) in timed.enumerated() {
            for other in timed.dropFirst(index + 1) {
                guard event.start < other.end, other.start < event.end else { continue }
                clashing.insert(event)
                clashing.insert(other)
            }
        }
        return clashing
    }

    static func title(from start: Date, days: Double) -> String {
        let calendar = Calendar.current
        if days > 1.5 {
            return "Next \(Int(days.rounded())) days"
        }
        if calendar.isDateInToday(start) { return "Today" }
        if calendar.isDateInTomorrow(start) { return "Tomorrow" }
        return start.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Date parsing for tool arguments. Models emit ISO 8601 both with and without
/// fractional seconds, so both are accepted.
public enum ISO8601 {
    /// Built per call rather than cached: `ISO8601DateFormatter` is not
    /// `Sendable`, and tool calls are far too infrequent for the allocation to
    /// matter.
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    public static func date(from string: String) -> Date? {
        formatter(fractional: true).date(from: string)
            ?? formatter(fractional: false).date(from: string)
    }

    public static func string(from date: Date) -> String {
        formatter(fractional: false).string(from: date)
    }
}
