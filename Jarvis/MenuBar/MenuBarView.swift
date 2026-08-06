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

        Divider()

        Button("Demo: full turn") {
            Task { await HUDDemo.runTurn(on: appState) }
        }
        Button("Demo: confirmation gate") {
            Task { await HUDDemo.runConfirmation(on: appState) }
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit JARVIS") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
