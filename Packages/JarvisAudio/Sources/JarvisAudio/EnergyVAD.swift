import Foundation

/// Energy-threshold voice activity detector with trailing-silence end-of-speech.
/// Pure logic: callers feed per-buffer RMS values and timestamps, so it can be
/// unit-tested without an audio device and reused for barge-in detection.
public struct EnergyVAD: Sendable {
    public enum Event: Equatable, Sendable {
        case speechStarted
        case speechEnded
    }

    public struct Configuration: Sendable {
        /// RMS above this counts as speech (16-bit normalized 0...1 domain).
        public var speechThreshold: Float
        /// Trailing silence that ends an utterance.
        public var trailingSilence: TimeInterval
        /// Speech must be sustained this long before `speechStarted` fires
        /// (filters keyboard clicks and pops — matters for barge-in).
        public var minimumSpeechDuration: TimeInterval

        public init(
            speechThreshold: Float = 0.015,
            trailingSilence: TimeInterval = 0.7,
            minimumSpeechDuration: TimeInterval = 0.15
        ) {
            self.speechThreshold = speechThreshold
            self.trailingSilence = trailingSilence
            self.minimumSpeechDuration = minimumSpeechDuration
        }
    }

    public let configuration: Configuration

    private var speechActive = false
    private var candidateSpeechStart: TimeInterval?
    private var lastSpeechAt: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feed one buffer's RMS at a monotonically increasing timestamp (seconds).
    public mutating func process(rms: Float, at time: TimeInterval) -> Event? {
        let isLoud = rms >= configuration.speechThreshold

        if isLoud {
            lastSpeechAt = time
            if speechActive { return nil }
            if let start = candidateSpeechStart {
                if time - start >= configuration.minimumSpeechDuration {
                    speechActive = true
                    return .speechStarted
                }
            } else {
                candidateSpeechStart = time
            }
            return nil
        }

        candidateSpeechStart = nil
        if speechActive, let last = lastSpeechAt, time - last >= configuration.trailingSilence {
            speechActive = false
            lastSpeechAt = nil
            return .speechEnded
        }
        return nil
    }

    public mutating func reset() {
        speechActive = false
        candidateSpeechStart = nil
        lastSpeechAt = nil
    }

    /// RMS helper for PCM float buffers.
    public static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(into: Float(0)) { $0 += $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}
