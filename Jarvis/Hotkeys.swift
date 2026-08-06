import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Hold = push-to-talk, tap = toggle listening.
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.option]))
    /// Panic: cancel everything. The spec suggested ⌘⌥Esc, but that is the
    /// system Force Quit shortcut, so the default here is ⌥Esc (rebindable in
    /// Settings).
    static let panic = Self("panic", default: .init(.escape, modifiers: [.option]))

    /// Type instead of speaking.
    static let typeToTalk = Self("typeToTalk", default: .init(.space, modifiers: [.option, .shift]))

    /// Plain Escape, to dismiss whatever is on screen.
    ///
    /// Registered and unregistered around the HUD's visibility rather than left
    /// installed: this is a global hotkey, so while it is active Escape does not
    /// reach any other app. That is only acceptable while JARVIS is actually on
    /// screen and asking for attention.
    static let dismiss = Self("dismiss", default: .init(.escape))
}

/// Global hotkey wiring. Uses Carbon hotkeys via KeyboardShortcuts, so no
/// Accessibility permission is needed for activation.
@MainActor
final class HotkeyManager {
    /// Presses shorter than this are taps (toggle); longer are holds (PTT).
    private static let tapThreshold: TimeInterval = 0.35

    private let appState: AppState
    private var pressBegan: Date?
    private var wasListeningAtPress = false

    init(appState: AppState) {
        self.appState = appState

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            self?.pushToTalkDown()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            self?.pushToTalkUp()
        }
        KeyboardShortcuts.onKeyDown(for: .panic) { [weak self] in
            self?.appState.panic()
        }
        KeyboardShortcuts.onKeyDown(for: .typeToTalk) { [weak self] in
            self?.appState.beginComposing()
        }
        KeyboardShortcuts.onKeyDown(for: .dismiss) { [weak self] in
            self?.appState.dismiss()
        }

        // Escape stays disabled until the HUD is up — see the note on the name.
        KeyboardShortcuts.disable(.dismiss)
    }

    /// Escape is only claimed while JARVIS is visible, so it behaves normally
    /// in every other app the rest of the time.
    static func setDismissHotkeyEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(.dismiss)
        } else {
            KeyboardShortcuts.disable(.dismiss)
        }
    }

    private func pushToTalkDown() {
        pressBegan = .now
        wasListeningAtPress = appState.turnState == .listening
        if !wasListeningAtPress {
            appState.beginListening()
        }
    }

    private func pushToTalkUp() {
        defer { pressBegan = nil }
        let held = pressBegan.map { Date.now.timeIntervalSince($0) } ?? 0

        if wasListeningAtPress {
            // Already listening from a previous tap-toggle: any press stops.
            appState.endListening()
        } else if held >= Self.tapThreshold {
            // Held: classic push-to-talk, release ends the utterance.
            appState.endListening()
        }
        // else: quick tap started listening and stays on (toggle mode).
    }
}
