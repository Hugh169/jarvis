import Foundation

/// A day laid out on a timeline, for the HUD to draw rather than describe.
///
/// The point of the two-channel rule is that structured things should be seen,
/// not read aloud — and markdown in the detail pane was still just words. This
/// is the model behind `display_schedule`: the assistant hands over what
/// happens and when, and the HUD renders the shape of the day.
public struct Schedule: Sendable, Equatable {
    public let title: String
    public let items: [ScheduleItem]

    public init(title: String, items: [ScheduleItem]) {
        self.title = title
        self.items = items
    }
}

public struct ScheduleItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// Already formatted for display — "7:00 am", "half eleven". The assistant
    /// decides how a time should read; this doesn't re-parse it.
    public let time: String
    public let title: String
    public let location: String?
    /// Minutes to get here from the previous item, drawn as the connector
    /// between them. Nil means no travel leg to show.
    public let travelMinutes: Int?
    public let travelMode: TravelDepiction?
    /// Overlaps something else. The one thing in the HUD allowed to go amber
    /// besides a confirmation — it means "this needs your attention".
    public let clashes: Bool

    public init(
        id: UUID = UUID(),
        time: String,
        title: String,
        location: String? = nil,
        travelMinutes: Int? = nil,
        travelMode: TravelDepiction? = nil,
        clashes: Bool = false
    ) {
        self.id = id
        self.time = time
        self.title = title
        self.location = location
        self.travelMinutes = travelMinutes
        self.travelMode = travelMode
        self.clashes = clashes
    }
}

/// How to get there, as a glyph. Deliberately small — the timeline shows a
/// mode at a glance, it isn't a routing UI.
public enum TravelDepiction: String, Sendable, Equatable, CaseIterable {
    case driving, walking, transit, cycling

    public init?(loose raw: String?) {
        guard let raw = raw?.lowercased() else { return nil }
        switch raw {
        case "drive", "driving", "car": self = .driving
        case "walk", "walking", "on foot": self = .walking
        case "transit", "bus", "train", "public", "public transport": self = .transit
        case "cycle", "cycling", "bike": self = .cycling
        default: return nil
        }
    }

    public var symbolName: String {
        switch self {
        case .driving: "car.fill"
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        case .cycling: "bicycle"
        }
    }
}
