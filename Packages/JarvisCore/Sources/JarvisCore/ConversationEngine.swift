import Foundation

/// Owns turn state and (in later phases) orchestrates STT → Claude → TTS.
/// Phase 1: just the state machine plus an observable stream of state changes.
public actor ConversationEngine {
    public private(set) var state: TurnState = .idle

    private var continuations: [UUID: AsyncStream<TurnState>.Continuation] = [:]

    public init() {}

    /// Observe state changes. Each caller gets its own stream; the current state
    /// is emitted immediately.
    public func states() -> AsyncStream<TurnState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: TurnState.self)
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuations[id] = continuation
        return stream
    }

    /// Apply an event. Invalid events for the current state are ignored (returns false).
    @discardableResult
    public func handle(_ event: TurnEvent) -> Bool {
        guard let next = state.applying(event) else { return false }
        state = next
        for continuation in continuations.values {
            continuation.yield(next)
        }
        return true
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
