import Testing
@testable import JarvisCore

@Suite struct TurnStateTests {
    @Test func happyPathTurn() {
        var state = TurnState.idle
        for (event, expected): (TurnEvent, TurnState) in [
            (.listenStarted, .listening),
            (.transcriptReady, .thinking),
            (.speechStarted, .speaking),
            (.speechFinished, .idle),
        ] {
            state = state.applying(event) ?? state
            #expect(state == expected)
        }
    }

    @Test func bargeInWhileSpeakingReturnsToListening() {
        #expect(TurnState.speaking.applying(.bargeIn) == .listening)
        #expect(TurnState.thinking.applying(.bargeIn) == .listening)
    }

    @Test func cancelAlwaysReturnsToIdle() {
        for state: TurnState in [.idle, .listening, .thinking, .speaking] {
            #expect(state.applying(.cancelled) == .idle)
        }
    }

    @Test func invalidEventsAreRejected() {
        #expect(TurnState.idle.applying(.transcriptReady) == nil)
        #expect(TurnState.idle.applying(.bargeIn) == nil)
        #expect(TurnState.listening.applying(.speechStarted) == nil)
    }

    /// Pressing push-to-talk mid-reply must go through `.bargeIn`, not
    /// `.listenStarted` — the latter is rejected from these states, which
    /// silently left JARVIS talking into its own next prompt.
    @Test func listenStartedIsNotAShortcutOutOfAnActiveTurn() {
        #expect(TurnState.speaking.applying(.listenStarted) == nil)
        #expect(TurnState.thinking.applying(.listenStarted) == nil)
        #expect(TurnState.speaking.applying(.bargeIn) == .listening)
        #expect(TurnState.thinking.applying(.bargeIn) == .listening)
    }

    @Test func toolOnlyTurnCanFinishWithoutSpeaking() {
        #expect(TurnState.thinking.applying(.speechFinished) == .idle)
    }

    @Test func engineIgnoresInvalidEvents() async {
        let engine = ConversationEngine()
        #expect(await engine.handle(.listenStarted))
        #expect(!(await engine.handle(.speechFinished)))
        #expect(await engine.state == .listening)
    }
}
