import Testing
import Foundation
@testable import JarvisCore

@Suite struct ToolActivityTests {
    private func activity(_ name: String = "get_weather", started: Date = .now) -> ToolActivity {
        let descriptor = ToolPresentation.descriptor(for: name)
        return ToolActivity(
            toolName: name,
            title: descriptor.title,
            bundleIdentifier: descriptor.bundleIdentifier,
            symbolName: descriptor.symbolName,
            startedAt: started
        )
    }

    // `finish` is mutating, so results are bound to a local before #expect —
    // the macro captures its subexpressions immutably.

    @Test func finishRecordsStatusAndDuration() {
        var log = ToolActivityLog()
        let start = Date(timeIntervalSince1970: 1000)
        let item = activity(started: start)
        log.begin(item)
        #expect(log.hasRunning)

        let didFinish = log.finish(id: item.id, status: .succeeded, at: start.addingTimeInterval(0.94))
        #expect(didFinish)
        #expect(!log.hasRunning)
        #expect(abs(log.activities[0].elapsed() - 0.94) < 0.0001)
    }

    @Test func lateDuplicateResultCannotRewriteHistory() {
        var log = ToolActivityLog()
        let item = activity()
        log.begin(item)
        let first = log.finish(id: item.id, status: .succeeded)
        // A second result arriving late must not flip a success into a failure.
        let second = log.finish(id: item.id, status: .failed("timeout"))
        #expect(first)
        #expect(!second)
        #expect(log.activities[0].status == .succeeded)
    }

    @Test func unknownIDIsIgnored() {
        var log = ToolActivityLog()
        log.begin(activity())
        let result = log.finish(id: UUID(), status: .succeeded)
        #expect(!result)
    }

    @Test func nonTerminalStatusCannotFinish() {
        var log = ToolActivityLog()
        let item = activity()
        log.begin(item)
        let result = log.finish(id: item.id, status: .running)
        #expect(!result)
        #expect(log.hasRunning)
    }

    @Test func awaitingConfirmationCountsAsRunning() {
        var log = ToolActivityLog()
        var item = activity("send_message")
        item.status = .awaitingConfirmation
        log.begin(item)
        #expect(log.hasRunning)
    }

    @Test func clearEmptiesTheLog() {
        var log = ToolActivityLog()
        log.begin(activity())
        log.clear()
        #expect(log.isEmpty)
        #expect(!log.hasRunning)
    }

    @Test func elapsedIsLiveWhileRunning() {
        let start = Date(timeIntervalSince1970: 500)
        let item = activity(started: start)
        #expect(item.elapsed(now: start.addingTimeInterval(2)) == 2)
    }

    @Test func knownToolsMapToApps() {
        #expect(ToolPresentation.descriptor(for: "get_weather").bundleIdentifier == "com.apple.weather")
        #expect(ToolPresentation.descriptor(for: "send_message").title == "Sending a message")
    }

    @Test func unknownToolsFallBackGracefully() {
        let descriptor = ToolPresentation.descriptor(for: "github__create_issue")
        #expect(descriptor.title == "Create issue")
        #expect(descriptor.bundleIdentifier == nil)
        #expect(descriptor.symbolName == "wrench.and.screwdriver")
    }

    @Test func humaniseHandlesPlainAndNamespacedNames() {
        #expect(ToolPresentation.humanise("set_volume") == "Set volume")
        #expect(ToolPresentation.humanise("linear__list_issues") == "List issues")
        #expect(ToolPresentation.humanise("screenshot") == "Screenshot")
    }
}
