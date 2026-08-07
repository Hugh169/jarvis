import Testing
import Foundation
import JarvisCore
@testable import JarvisTools

/// The timeline is now built from calendar data in code rather than from
/// whatever the model chose to pass to `display_schedule`, so overlap is
/// arithmetic and has to be right.
@Suite struct ScheduleBuildingTests {
    private func event(
        _ title: String,
        _ startHour: Int,
        _ endHour: Int,
        allDay: Bool = false,
        location: String? = nil
    ) -> CalendarEvent {
        let day = Date(timeIntervalSinceReferenceDate: 0)
        return CalendarEvent(
            title: title,
            start: day.addingTimeInterval(TimeInterval(startHour) * 3600),
            end: day.addingTimeInterval(TimeInterval(endHour) * 3600),
            isAllDay: allDay,
            location: location
        )
    }

    @Test func sequentialEventsDontClash() {
        let events = [event("Reformer", 7, 8), event("Work", 9, 17)]
        #expect(ListEventsTool.overlapping(events).isEmpty)
    }

    /// Touching at the boundary is a handover, not a clash — a 9-to-10 and a
    /// 10-to-11 are exactly how a back-to-back morning looks.
    @Test func touchingAtTheBoundaryIsNotAClash() {
        let events = [event("First", 9, 10), event("Second", 10, 11)]
        #expect(ListEventsTool.overlapping(events).isEmpty)
    }

    @Test func realOverlapFlagsBothSides() {
        let netball = event("Netball", 11, 12)
        let soccer = event("Soccer", 11, 13)
        let clashing = ListEventsTool.overlapping([netball, soccer])
        #expect(clashing.count == 2)
        #expect(clashing.contains(netball))
        #expect(clashing.contains(soccer))
    }

    @Test func containedEventClashesWithItsContainer() {
        let long = event("Trials", 9, 15)
        let short = event("Dentist", 11, 12)
        #expect(ListEventsTool.overlapping([long, short]).count == 2)
    }

    /// All-day events overlap everything by definition. Counting them would
    /// paint the entire day amber and make the signal worthless.
    @Test func allDayEventsAreNeverClashes() {
        let trials = event("HSC trials", 0, 24, allDay: true)
        let soccer = event("Soccer", 11, 12)
        #expect(ListEventsTool.overlapping([trials, soccer]).isEmpty)
    }

    @Test func buildsATimelineInOrderWithLocations() {
        let schedule = ListEventsTool.schedule(
            for: [event("Reformer", 7, 8, location: "Mona Vale"), event("Netball", 11, 12)],
            from: Date(timeIntervalSinceReferenceDate: 0),
            days: 1
        )
        #expect(schedule.items.count == 2)
        #expect(schedule.items[0].title == "Reformer")
        #expect(schedule.items[0].location == "Mona Vale")
        #expect(schedule.items[1].location == nil)
        #expect(schedule.items.allSatisfy { !$0.clashes })
    }

    @Test func clashesReachTheTimeline() {
        let schedule = ListEventsTool.schedule(
            for: [event("Netball", 11, 12), event("Soccer", 11, 13), event("Dinner", 17, 19)],
            from: Date(timeIntervalSinceReferenceDate: 0),
            days: 1
        )
        #expect(schedule.items.map(\.clashes) == [true, true, false])
    }

    // MARK: Heading

    @Test func namesTheDayWhenItIsTodayOrTomorrow() {
        #expect(ListEventsTool.title(from: .now, days: 1) == "Today")
        #expect(ListEventsTool.title(from: .now.addingTimeInterval(86_400), days: 1) == "Tomorrow")
    }

    @Test func aWiderWindowIsDescribedAsARange() {
        #expect(ListEventsTool.title(from: .now, days: 7) == "Next 7 days")
    }

    /// A day that is neither today nor tomorrow gets named, not left blank.
    @Test func otherDaysGetADate() {
        let title = ListEventsTool.title(from: .now.addingTimeInterval(86_400 * 5), days: 1)
        #expect(!title.isEmpty)
        #expect(title != "Today" && title != "Tomorrow")
    }
}
