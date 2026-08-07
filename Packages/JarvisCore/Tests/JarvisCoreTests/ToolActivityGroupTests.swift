import Testing
import Foundation
@testable import JarvisCore

@Suite struct ToolActivityGroupTests {
    private func activity(
        _ name: String,
        subtitle: String? = nil,
        status: ToolActivity.Status = .succeeded,
        seconds: TimeInterval = 1
    ) -> ToolActivity {
        let started = Date(timeIntervalSinceReferenceDate: 0)
        return ToolActivity(
            toolName: name,
            title: name,
            subtitle: subtitle,
            bundleIdentifier: nil,
            symbolName: "wrench",
            status: status,
            startedAt: started,
            finishedAt: started.addingTimeInterval(seconds)
        )
    }

    @Test func collapsesARunOfTheSameTool() {
        let groups = ToolActivityGroup.group([
            activity("travel_time_to"), activity("travel_time_to"), activity("travel_time_to"),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].count == 3)
    }

    /// Two searches either side of a calendar lookup happened at different
    /// moments; merging them would misrepresent the order of work.
    @Test func onlyAdjacentRunsMerge() {
        let groups = ToolActivityGroup.group([
            activity("search_mail"), activity("list_events"), activity("search_mail"),
        ])
        #expect(groups.map(\.count) == [1, 1, 1])
        #expect(groups.map { $0.first.toolName } == ["search_mail", "list_events", "search_mail"])
    }

    @Test func emptyInputMakesNoGroups() {
        #expect(ToolActivityGroup.group([]).isEmpty)
    }

    /// Each group is keyed on its first member, so SwiftUI doesn't reuse a row
    /// across two different runs of the same tool.
    @Test func identityComesFromTheFirstMember() {
        let first = activity("a")
        let groups = ToolActivityGroup.group([first, activity("a")])
        #expect(groups[0].id == first.id)
    }

    // MARK: Status

    /// One failure among five is the thing worth seeing.
    @Test func failureOutranksSuccess() {
        let groups = ToolActivityGroup.group([
            activity("t"), activity("t", status: .failed("no route")), activity("t"),
        ])
        #expect(groups[0].status == .failed("no route"))
    }

    @Test func unfinishedWorkOutranksSuccess() {
        let groups = ToolActivityGroup.group([activity("t"), activity("t", status: .running)])
        #expect(groups[0].status == .running)
    }

    /// A pending decision outranks work still in flight — it's the one that
    /// needs the user.
    @Test func awaitingConfirmationOutranksRunning() {
        let groups = ToolActivityGroup.group([
            activity("t", status: .running), activity("t", status: .awaitingConfirmation),
        ])
        #expect(groups[0].status == .awaitingConfirmation)
    }

    @Test func allSucceededIsSucceeded() {
        let groups = ToolActivityGroup.group([activity("t"), activity("t")])
        #expect(groups[0].status == .succeeded)
    }

    // MARK: Presentation

    @Test func subtitlesJoinInOrder() {
        let groups = ToolActivityGroup.group([
            activity("t", subtitle: "Reformer"),
            activity("t", subtitle: "Netball"),
        ])
        #expect(groups[0].subtitle == "Reformer, Netball")
    }

    /// Falls back to nil so the chip can show the tool name instead of an
    /// empty second line.
    @Test func noSubtitlesMeansNone() {
        #expect(ToolActivityGroup.group([activity("t"), activity("t")])[0].subtitle == nil)
    }

    @Test func partialSubtitlesSkipTheBlanks() {
        let groups = ToolActivityGroup.group([
            activity("t", subtitle: "Reformer"), activity("t"), activity("t", subtitle: ""),
        ])
        #expect(groups[0].subtitle == "Reformer")
    }

    /// Time spent, not wall clock: members may have run concurrently.
    @Test func elapsedSumsTheMembers() {
        let groups = ToolActivityGroup.group([
            activity("t", seconds: 0.5), activity("t", seconds: 1.5),
        ])
        #expect(groups[0].elapsed() == 2.0)
    }
}
