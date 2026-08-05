import Foundation

/// STT abstraction. Two conforming implementations are planned:
/// AppleSpeechTranscriber (Phase 2, on-device) and ScribeTranscriber
/// (Phase 5+, ElevenLabs Scribe v2 Realtime over WebSocket).
public protocol SpeechTranscriber: AnyObject, Sendable {
    /// Partial hypotheses as they stream in. A new stream per utterance.
    var partials: AsyncStream<String> { get }
    /// Begin an utterance.
    func start() async throws
    /// End the utterance and return the final transcript.
    func finish() async throws -> String
    /// Abandon the utterance without producing a transcript.
    func cancel()
}

/// Deterministic transcriber for tests and the CLI harness: replays scripted
/// partials and returns a fixed final transcript.
public final class ScriptedTranscriber: SpeechTranscriber, @unchecked Sendable {
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
