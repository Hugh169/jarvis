import Testing
import Foundation
@testable import JarvisAudio

@Suite struct EnergyVADTests {
    private func makeVAD() -> EnergyVAD {
        EnergyVAD(configuration: .init(
            speechThreshold: 0.02,
            trailingSilence: 0.5,
            minimumSpeechDuration: 0.1
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

    @Test func rmsOfKnownSignal() {
        #expect(abs(EnergyVAD.rms(of: [0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
        #expect(EnergyVAD.rms(of: []) == 0)
    }
}
