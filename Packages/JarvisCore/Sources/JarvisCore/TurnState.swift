import Foundation

/// The assistant's turn lifecycle. Pure value type so transitions are unit-testable
/// independently of the actor that owns them.
public enum TurnState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
}

public enum TurnEvent: Equatable, Sendable {
    /// Push-to-talk pressed (or toggle activated).
    case listenStarted
    /// Push-to-talk released / VAD detected end of speech, with the final transcript.
    case transcriptReady
    /// First audio of the reply is playing.
    case speechStarted
    /// Playback queue drained.
    case speechFinished
    /// User spoke over the assistant (barge-in) — treated as a new listen.
    case bargeIn
    /// Panic key, or an unrecoverable error: drop everything.
    case cancelled
}

extension TurnState {
    /// Returns the next state, or nil if the event is not valid in this state.
    public func applying(_ event: TurnEvent) -> TurnState? {
        switch (self, event) {
        case (_, .cancelled): return .idle
        case (.idle, .listenStarted): return .listening
        case (.listening, .transcriptReady): return .thinking
        case (.thinking, .speechStarted): return .speaking
        // Tool-only turns can finish without ever speaking.
        case (.thinking, .speechFinished): return .idle
        case (.speaking, .speechFinished): return .idle
        case (.speaking, .bargeIn), (.thinking, .bargeIn): return .listening
        default: return nil
        }
    }
}
