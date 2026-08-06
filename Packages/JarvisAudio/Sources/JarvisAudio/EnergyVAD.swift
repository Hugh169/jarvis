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
        /// Fixed RMS threshold, and the fallback before the room is measured.
        public var speechThreshold: Float
        /// Trailing silence that ends an utterance.
        public var trailingSilence: TimeInterval
        /// Speech must be sustained this long before `speechStarted` fires
        /// (filters keyboard clicks and pops — matters for barge-in).
        public var minimumSpeechDuration: TimeInterval

        /// Track the room's noise floor and set the threshold relative to it.
        ///
        /// A fixed absolute threshold cannot work across microphones and rooms:
        /// too high and speech never registers, so end-of-speech never fires;
        /// too low and the room itself reads as continuous speech, so the
        /// utterance never closes. Either way you have to end every turn by
        /// hand. Measuring the floor removes the guess.
        public var adaptive: Bool
        /// How far above the noise floor counts as speech.
        public var noiseRatio: Float
        /// Bounds on the adapted threshold, so a silent room doesn't make it
        /// hair-trigger and a loud one doesn't make it deaf.
        public var minThreshold: Float
        public var maxThreshold: Float
        /// Time spent measuring the room before the first decision. Paid once
        /// per session, not once per turn — the floor carries between turns.
        public var calibrationDuration: TimeInterval

        public init(
            speechThreshold: Float = 0.015,
            trailingSilence: TimeInterval = 0.7,
            minimumSpeechDuration: TimeInterval = 0.15,
            adaptive: Bool = true,
            noiseRatio: Float = 3.5,
            minThreshold: Float = 0.006,
            maxThreshold: Float = 0.08,
            calibrationDuration: TimeInterval = 0.3
        ) {
            self.speechThreshold = speechThreshold
            self.trailingSilence = trailingSilence
            self.minimumSpeechDuration = minimumSpeechDuration
            self.adaptive = adaptive
            self.noiseRatio = noiseRatio
            self.minThreshold = minThreshold
            self.maxThreshold = maxThreshold
            self.calibrationDuration = calibrationDuration
        }

        /// Detecting the user over the assistant's own playback.
        ///
        /// Deliberately far less sensitive than the listening config: on
        /// speakers the microphone hears JARVIS itself, and a normal threshold
        /// makes it interrupt its own sentence. A high bar plus a longer
        /// sustain means a real interruption still lands quickly while its own
        /// voice and a stray cough do not.
        public static func bargeIn(sensitivity: Float = 0.5) -> Configuration {
            // sensitivity 0…1 maps to a threshold from forgiving to twitchy.
            let threshold = 0.10 - (0.07 * max(0, min(1, sensitivity)))
            return Configuration(
                speechThreshold: threshold,
                trailingSilence: 0.7,
                minimumSpeechDuration: 0.35,
                // Fixed, not adaptive. While JARVIS is speaking the "background"
                // is JARVIS, so adapting would raise the bar to its own voice
                // and you'd have to shout to interrupt.
                adaptive: false
            )
        }
    }

    public let configuration: Configuration

    private var speechActive = false
    private var candidateSpeechStart: TimeInterval?
    private var lastSpeechAt: TimeInterval?
    private var noiseFloor: Float?
    private var calibrationStart: TimeInterval?
    private var calibrationMin: Float = .greatestFiniteMagnitude

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feed one buffer's RMS at a monotonically increasing timestamp (seconds).
    /// Current effective threshold — the adapted one when adaptive, otherwise
    /// the fixed value. Exposed so the app can log why it did or didn't trigger.
    public var effectiveThreshold: Float {
        guard configuration.adaptive, let floor = noiseFloor else {
            return configuration.speechThreshold
        }
        return min(max(floor * configuration.noiseRatio, configuration.minThreshold),
                   configuration.maxThreshold)
    }

    /// Measured background level, once known.
    public var measuredNoiseFloor: Float? { noiseFloor }

    public mutating func process(rms: Float, at time: TimeInterval) -> Event? {
        // Measure the room before judging anything. Without this the very first
        // frames are compared against a guess: in a noisy room that guess reads
        // the room itself as speech, speech never "ends", and every turn has to
        // be closed by hand.
        if configuration.adaptive, noiseFloor == nil {
            let start = calibrationStart ?? time
            calibrationStart = start
            calibrationMin = min(calibrationMin, rms)
            guard time - start >= configuration.calibrationDuration else { return nil }
            noiseFloor = calibrationMin
            calibrationStart = nil
            calibrationMin = .greatestFiniteMagnitude
        }

        let threshold = effectiveThreshold

        // Keep tracking the background between utterances. Frozen during speech
        // — adapting then would chase the voice upward and the utterance would
        // never close.
        if configuration.adaptive, !speechActive, rms < threshold {
            noiseFloor = noiseFloor.map { $0 * 0.93 + rms * 0.07 } ?? rms
        }

        let isLoud = rms >= threshold

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

    /// Ends the current utterance but keeps the measured noise floor — that
    /// describes the room, not the utterance, and relearning it every turn
    /// would leave the first second of each one mis-thresholded.
    public mutating func reset() {
        speechActive = false
        candidateSpeechStart = nil
        lastSpeechAt = nil
    }

    /// Forgets the room too, for a new device or location.
    public mutating func resetIncludingNoiseFloor() {
        reset()
        noiseFloor = nil
        calibrationStart = nil
        calibrationMin = .greatestFiniteMagnitude
    }

    /// RMS helper for PCM float buffers.
    public static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(into: Float(0)) { $0 += $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}
