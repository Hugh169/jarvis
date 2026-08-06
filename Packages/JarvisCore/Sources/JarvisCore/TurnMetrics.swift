import Foundation

/// Timing for one turn. The number that matters is `timeToFirstAudio`:
/// end-of-speech to the first spoken syllable. Target < 1.2s, investigate > 1.5s.
public struct TurnMetrics: Sendable, Equatable {
    public var endOfSpeech: Date?
    public var transcriptReady: Date?
    public var requestSent: Date?
    public var firstTextDelta: Date?
    public var firstAudioChunk: Date?
    public var firstAudioPlayed: Date?

    public init() {}

    /// The headline figure.
    public var timeToFirstAudio: TimeInterval? {
        interval(from: endOfSpeech, to: firstAudioPlayed)
    }

    /// How long transcription took after you stopped speaking.
    public var transcriptionTime: TimeInterval? {
        interval(from: endOfSpeech, to: transcriptReady)
    }

    /// Model latency to its first token.
    public var timeToFirstToken: TimeInterval? {
        interval(from: requestSent, to: firstTextDelta)
    }

    /// How long TTS took to return audio for the first sentence.
    public var synthesisTime: TimeInterval? {
        interval(from: firstTextDelta, to: firstAudioChunk)
    }

    private func interval(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    /// Whether the turn met the spec's budget. Nil when the turn didn't speak.
    public var meetsBudget: Bool? {
        timeToFirstAudio.map { $0 < 1.2 }
    }

    /// One line for the debug log, breaking the budget into its parts so a
    /// regression points at the stage that caused it.
    public var summary: String {
        func ms(_ value: TimeInterval?) -> String {
            value.map { "\(Int($0 * 1000))ms" } ?? "—"
        }
        return """
            turn: first audio \(ms(timeToFirstAudio)) \
            (stt \(ms(transcriptionTime)), \
            ttft \(ms(timeToFirstToken)), \
            tts \(ms(synthesisTime)))
            """
    }
}
