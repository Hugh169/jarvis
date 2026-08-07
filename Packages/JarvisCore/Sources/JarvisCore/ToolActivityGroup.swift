import Foundation

/// Consecutive calls to the same tool, collapsed into one row.
///
/// Planning a day fires `travel_time_to` once per leg, and five identical
/// chips tell you five things happened and nothing about what. Grouped, the
/// count goes on the title and the arguments become the subtitle — so it reads
/// "Checking how long it takes ×5 · Reformer Classic, Netball courts".
///
/// Lives here rather than in the view because it is entirely logic — worst
/// status wins, only adjacent runs merge — and none of that is checkable from
/// inside a SwiftUI file.
public struct ToolActivityGroup: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let members: [ToolActivity]

    public init(id: UUID, members: [ToolActivity]) {
        self.id = id
        self.members = members
    }

    public var first: ToolActivity { members[0] }
    public var count: Int { members.count }

    /// Worst status wins: one failure among five is the thing worth seeing,
    /// and anything unfinished outranks a settled result.
    public var status: ToolActivity.Status {
        if let failed = members.first(where: { if case .failed = $0.status { true } else { false } }) {
            return failed.status
        }
        if members.contains(where: { $0.status == .awaitingConfirmation }) {
            return .awaitingConfirmation
        }
        if members.contains(where: { $0.status == .running }) { return .running }
        return .succeeded
    }

    /// Summed, not wall-clock: the chips report time spent, and the members of
    /// a group may have run concurrently or one after another.
    public func elapsed(now: Date = .now) -> TimeInterval {
        members.reduce(0) { $0 + $1.elapsed(now: now) }
    }

    public var subtitle: String? {
        let parts = members.compactMap(\.subtitle).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Only *consecutive* runs collapse. Two searches either side of a
    /// calendar lookup happened at different moments in the turn and reading
    /// them as one event would misrepresent the order of work.
    public static func group(_ activities: [ToolActivity]) -> [ToolActivityGroup] {
        var groups: [[ToolActivity]] = []
        for activity in activities {
            if let last = groups.last?.last, last.toolName == activity.toolName {
                groups[groups.count - 1].append(activity)
            } else {
                groups.append([activity])
            }
        }
        return groups.map { ToolActivityGroup(id: $0[0].id, members: $0) }
    }
}
