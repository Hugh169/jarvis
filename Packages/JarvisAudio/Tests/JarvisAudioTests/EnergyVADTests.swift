import Testing
import Foundation
@testable import JarvisAudio

@Suite struct EnergyVADTests {
    /// Fixed threshold: these cover the start/end timing state machine, which
    /// is independent of how the threshold was chosen. Calibration has its own
    /// tests below.
    private func makeVAD() -> EnergyVAD {
        EnergyVAD(configuration: .init(
            speechThreshold: 0.02,
            trailingSilence: 0.5,
            minimumSpeechDuration: 0.1,
            adaptive: false
        ))
    }

    @Test func detectsSpeechAfterMinimumDuration() {
        var vad = makeVAD()
        #expect(vad.process(rms: 0.1, at: 0.00) == nil)   // candidate only
        #expect(vad.process(rms: 0.1, at: 0.05) == nil)   // still under min duration
        #expect(vad.process(rms: 0.1, at: 0.12) == .speechStarted)
    }

    @Test func briefClickDoesNotTriggerSpeech() {
        var vad = makeVAD()
        #expect(vad.process(rms: 0.5, at: 0.00) == nil)
        #expect(vad.process(rms: 0.001, at: 0.05) == nil) // silence resets the candidate
        #expect(vad.process(rms: 0.5, at: 0.10) == nil)   // new candidate, not started
    }

    @Test func endsAfterTrailingSilence() {
        var vad = makeVAD()
        _ = vad.process(rms: 0.1, at: 0.0)
        #expect(vad.process(rms: 0.1, at: 0.2) == .speechStarted)
        #expect(vad.process(rms: 0.001, at: 0.4) == nil)  // silence, not long enough
        #expect(vad.process(rms: 0.001, at: 0.69) == nil)
        #expect(vad.process(rms: 0.001, at: 0.71) == .speechEnded) // 0.5s past last speech at 0.2
    }

    @Test func speechResumingCancelsPendingEnd() {
        var vad = makeVAD()
        _ = vad.process(rms: 0.1, at: 0.0)
        _ = vad.process(rms: 0.1, at: 0.2)
        #expect(vad.process(rms: 0.001, at: 0.5) == nil)
        #expect(vad.process(rms: 0.1, at: 0.6) == nil)    // speech resumes
        #expect(vad.process(rms: 0.001, at: 0.9) == nil)  // silence clock restarts
        #expect(vad.process(rms: 0.001, at: 1.11) == .speechEnded)
    }

    @Test func bargeInIsLessSensitiveThanListening() {
        let listening = EnergyVAD.Configuration()
        let barge = EnergyVAD.Configuration.bargeIn()
        // Must not trip on the assistant's own voice leaking into the mic.
        #expect(barge.speechThreshold > listening.speechThreshold)
        #expect(barge.minimumSpeechDuration > listening.minimumSpeechDuration)
    }

    @Test func bargeInSensitivityIsMonotonic() {
        let twitchy = EnergyVAD.Configuration.bargeIn(sensitivity: 1)
        let forgiving = EnergyVAD.Configuration.bargeIn(sensitivity: 0)
        #expect(twitchy.speechThreshold < forgiving.speechThreshold)
        // Out-of-range values must clamp rather than invert the mapping.
        #expect(EnergyVAD.Configuration.bargeIn(sensitivity: 5).speechThreshold
                == twitchy.speechThreshold)
        #expect(EnergyVAD.Configuration.bargeIn(sensitivity: -5).speechThreshold
                == forgiving.speechThreshold)
    }

    @Test func quietPlaybackBleedDoesNotTripBargeIn() {
        var vad = EnergyVAD(configuration: .bargeIn())
        // Typical level of JARVIS leaking back through speakers.
        var time = 0.0
        var fired = false
        while time < 2.0 {
            if vad.process(rms: 0.05, at: time) == .speechStarted { fired = true }
            time += 0.05
        }
        #expect(!fired)
    }

    @Test func realSpeechTripsBargeInQuickly() {
        var vad = EnergyVAD(configuration: .bargeIn())
        var started: TimeInterval?
        var time = 0.0
        while time < 1.0, started == nil {
            if vad.process(rms: 0.35, at: time) == .speechStarted { started = time }
            time += 0.05
        }
        let detected = try! #require(started)
        // Comfortably inside the spec's 200ms-to-silence budget once detected.
        #expect(detected <= 0.4)
    }

    /// Feeds a run of frames at 20ms and returns the events, in order.
    private func run(
        _ vad: inout EnergyVAD,
        levels: [(rms: Float, seconds: Double)],
        from start: Double = 0
    ) -> [EnergyVAD.Event] {
        var time = start
        var events: [EnergyVAD.Event] = []
        for segment in levels {
            var elapsed = 0.0
            while elapsed < segment.seconds {
                if let event = vad.process(rms: segment.rms, at: time) { events.append(event) }
                time += 0.02
                elapsed += 0.02
            }
        }
        return events
    }

    // The two ways a fixed threshold strands the user on push-to-talk.

    /// Quiet mic: speech peaks below the old 0.015 constant, so speech never
    /// "started" and therefore could never end.
    @Test func quietMicrophoneStillDetectsAStartAndAnEnd() {
        var vad = EnergyVAD()
        let events = run(&vad, levels: [
            (0.0008, 0.6),   // room tone, well below the old threshold
            (0.010, 1.2),    // speech — quiet, but far above this room's floor
            (0.0008, 1.0),   // silence
        ])
        #expect(events == [.speechStarted, .speechEnded])
    }

    /// Noisy room: the floor sits above the old constant, so the room read as
    /// continuous speech and the utterance never closed.
    @Test func noisyRoomStillClosesTheUtterance() {
        var vad = EnergyVAD()
        let events = run(&vad, levels: [
            (0.020, 0.8),    // fans and traffic — above the old threshold
            (0.180, 1.2),    // actual speech
            (0.020, 1.2),    // back to room tone
        ])
        #expect(events == [.speechStarted, .speechEnded])
    }

    @Test func adaptedThresholdSitsAboveTheMeasuredFloor() {
        var vad = EnergyVAD()
        _ = run(&vad, levels: [(0.02, 1.0)])
        let floor = try! #require(vad.measuredNoiseFloor)
        #expect(abs(floor - 0.02) < 0.005)
        #expect(vad.effectiveThreshold > floor)
    }

    @Test func adaptedThresholdStaysWithinBounds() {
        var silent = EnergyVAD()
        _ = run(&silent, levels: [(0.0, 1.0)])
        #expect(silent.effectiveThreshold >= silent.configuration.minThreshold)

        var deafening = EnergyVAD()
        _ = run(&deafening, levels: [(0.9, 1.0)])
        #expect(deafening.effectiveThreshold <= deafening.configuration.maxThreshold)
    }

    /// The room doesn't change between turns, so the measurement shouldn't be
    /// thrown away — otherwise the first second of every turn is mis-thresholded.
    @Test func resetKeepsTheRoomButEndsTheUtterance() {
        var vad = EnergyVAD()
        _ = run(&vad, levels: [(0.02, 0.8), (0.2, 0.5)])
        let floor = vad.measuredNoiseFloor
        vad.reset()
        #expect(vad.measuredNoiseFloor == floor)

        vad.resetIncludingNoiseFloor()
        #expect(vad.measuredNoiseFloor == nil)
    }

    @Test func fixedModeIgnoresTheRoom() {
        var vad = EnergyVAD(configuration: .init(speechThreshold: 0.02, adaptive: false))
        _ = run(&vad, levels: [(0.001, 1.0)])
        #expect(vad.effectiveThreshold == 0.02)
        #expect(vad.measuredNoiseFloor == nil)
    }

    @Test func rmsOfKnownSignal() {
        #expect(abs(EnergyVAD.rms(of: [0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
        #expect(EnergyVAD.rms(of: []) == 0)
    }
}
