import SwiftUI
import JarvisCore

@MainActor
@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: appState.turnState.menuBarSymbol)
        }

        // No `Settings` scene: in an LSUIElement app it never produces a
        // window. SettingsPresenter owns an NSWindow instead.
    }
}

extension TurnState {
    var menuBarSymbol: String {
        switch self {
        case .idle: "waveform.circle"
        case .listening: "waveform.circle.fill"
        case .thinking: "hourglass.circle.fill"
        case .speaking: "speaker.wave.2.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        }
    }
}
