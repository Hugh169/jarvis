import Testing
import Foundation
@testable import JarvisCore

@Suite struct TurnMetricsTests {
    private func metrics(offsets: [WritableKeyPath<TurnMetrics, Date?>: TimeInterval]) -> TurnMetrics {
        let base = Date(timeIntervalSince1970: 10_000)
        var metrics = TurnMetrics()
        for (keyPath, offset) in offsets {
            metrics[keyPath: keyPath] = base.addingTimeInterval(offset)
        }
        return metrics
    }

    @Test func computesTimeToFirstAudio() {
        let m = metrics(offsets: [\.endOfSpeech: 0, \.firstAudioPlayed: 0.94])
        #expect(abs((m.timeToFirstAudio ?? 0) - 0.94) < 0.0001)
        #expect(m.meetsBudget == true)
    }

    @Test func flagsBudgetOverrun() {
        let m = metrics(offsets: [\.endOfSpeech: 0, \.firstAudioPlayed: 1.6])
        #expect(m.meetsBudget == false)
    }

    @Test func stageBreakdown() {
        let m = metrics(offsets: [
            \.endOfSpeech: 0,
            \.transcriptReady: 0.2,
            \.requestSent: 0.25,
            \.firstTextDelta: 0.6,
            \.firstAudioChunk: 0.85,
            \.firstAudioPlayed: 0.9,
        ])
        #expect(abs((m.transcriptionTime ?? 0) - 0.2) < 0.0001)
        #expect(abs((m.timeToFirstToken ?? 0) - 0.35) < 0.0001)
        #expect(abs((m.synthesisTime ?? 0) - 0.25) < 0.0001)
    }

    @Test func missingStagesAreNil() {
        let m = TurnMetrics()
        #expect(m.timeToFirstAudio == nil)
        #expect(m.meetsBudget == nil)
        #expect(m.summary.contains("—"))
    }

    /// A tool-only turn never speaks; that must not read as a zero-latency win.
    @Test func outOfOrderTimestampsYieldNil() {
        let m = metrics(offsets: [\.endOfSpeech: 5, \.firstAudioPlayed: 1])
        #expect(m.timeToFirstAudio == nil)
    }
}
