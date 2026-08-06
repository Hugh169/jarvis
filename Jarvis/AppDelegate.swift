import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeys: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon. LSUIElement covers the bundled build;
        // this covers `swift run` in dev mode.
        NSApp.setActivationPolicy(.accessory)
        let appState = AppState.shared
        hotkeys = HotkeyManager(appState: appState)

        // Deterministic UI exercise without touching the menu:
        //   open -a Jarvis --args --demo-turn
        appState.selectDefaultVoiceIfNeeded()

        let arguments = CommandLine.arguments
        if arguments.contains("--demo-turn") {
            appState.runDemoTurn()
        } else if arguments.contains("--demo-confirmation") {
            appState.runDemoConfirmation()
        } else if let index = arguments.firstIndex(of: "--say"),
                  arguments.indices.contains(index + 1) {
            // Full turn from text, no microphone: `open -a Jarvis --args --say "..."`
            let prompt = arguments[index + 1]
            // Give the voice lookup a moment so the first turn can speak.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                appState.runTextTurn(prompt)
            }
        }
    }
}
