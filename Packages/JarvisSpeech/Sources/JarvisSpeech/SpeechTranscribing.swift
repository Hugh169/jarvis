import Foundation
import AVFoundation

/// STT abstraction. Named `SpeechTranscribing` rather than the spec's
/// `SpeechTranscriber` because Apple's Speech framework now exports a class of
/// that exact name, and the collision is confusing wherever both are in scope.
///
/// Implementations: `AppleTranscriber` (on-device, Phase 2) and later an
/// ElevenLabs Scribe v2 Realtime client — a one-line swap at the call site.
public protocol SpeechTranscribing: AnyObject, Sendable {
    /// Partial hypotheses as they stream in, for live display.
    var partials: AsyncStream<String> { get }
    /// Begin an utterance. Throws if permission or the on-device model is unavailable.
    func start() async throws
    /// Feed captured audio. Format conversion is the implementation's problem.
    func append(_ buffer: AVAudioPCMBuffer)
    /// End the utterance and return the final transcript.
    func finish() async throws -> String
    /// Abandon the utterance without producing a transcript.
    func cancel()
}

/// Deterministic transcriber for tests and the CLI harness.
public final class ScriptedTranscriber: SpeechTranscribing, @unchecked Sendable {
    public let partials: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation
    private let scriptedPartials: [String]
    private let finalTranscript: String
    private let lock = NSLock()
    private var started = false

    public init(partials scripted: [String], final: String) {
        self.scriptedPartials = scripted
        self.finalTranscript = final
        (self.partials, self.partialContinuation) = AsyncStream.makeStream(of: String.self)
    }

    public func start() async throws {
        lock.withLock { started = true }
        for partial in scriptedPartials {
            partialContinuation.yield(partial)
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {}

    public func finish() async throws -> String {
        let wasStarted = lock.withLock { started }
        precondition(wasStarted, "finish() before start()")
        partialContinuation.finish()
        return finalTranscript
    }

    public func cancel() {
        partialContinuation.finish()
    }
}
