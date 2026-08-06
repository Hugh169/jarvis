import SwiftUI

@MainActor
struct MenuBarView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        // MenuBarExtra defaults to menu style: these render as menu items.
        Text(appState.turnState.displayName)

        Button("Toggle Listening") {
            appState.toggleListening()
        }

        Button("Type to JARVIS…") { appState.beginComposing() }

        Divider()

        Button("Demo: full turn") { appState.runDemoTurn() }
        Button("Demo: confirmation gate") { appState.runDemoConfirmation() }

        Divider()

        // Not SettingsLink: it can't front a window from an accessory app.
        Button("Settings…") { SettingsPresenter.show() }
            .keyboardShortcut(",")

        Divider()

        Button("Quit JARVIS") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
