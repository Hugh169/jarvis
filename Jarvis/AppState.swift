import Foundation
import Combine
import JarvisCore

/// UI-facing state, bridged from the ConversationEngine actor.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine = ConversationEngine()
    let keychain = KeychainStore()

    @Published private(set) var turnState: TurnState = .idle

    private lazy var hud = HUDController(appState: self)
    private var stateTask: Task<Void, Never>?

    private init() {
        stateTask = Task { [weak self] in
            guard let stream = await self?.engine.states() else { return }
            for await state in stream {
                self?.apply(state)
            }
        }
    }

    private func apply(_ state: TurnState) {
        turnState = state
        if state == .idle {
            hud.hide()
        } else {
            hud.show()
        }
    }

    // MARK: Intents (called by HotkeyManager and UI)

    func beginListening() {
        Task { await engine.handle(.listenStarted) }
    }

    func endListening() {
        // Phase 2 will hand the transcript to the brain here. For now the turn
        // just ends so the HUD hides.
        Task { await engine.handle(.cancelled) }
    }

    func toggleListening() {
        Task {
            if await engine.state == .listening {
                await engine.handle(.cancelled)
            } else {
                await engine.handle(.listenStarted)
            }
        }
    }

    /// Panic: cancel the in-flight turn, stop audio, kill running processes.
    /// Phase 1 only has the turn to cancel.
    func panic() {
        Task { await engine.handle(.cancelled) }
    }
}
