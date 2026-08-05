import Testing
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

    @Test func rmsOfKnownSignal() {
        #expect(abs(EnergyVAD.rms(of: [0.5, -0.5, 0.5, -0.5]) - 0.5) < 0.0001)
        #expect(EnergyVAD.rms(of: []) == 0)
    }
}
