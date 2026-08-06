import AppKit
import JarvisBrain

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
        appState.preloadKeys()
        appState.loadShortcuts()
        appState.selectDefaultVoiceIfNeeded()

        let arguments = CommandLine.arguments
        if arguments.contains("--demo-turn") {
            appState.runDemoTurn()
        } else if arguments.contains("--demo-confirmation") {
            appState.runDemoConfirmation()
        } else if let index = arguments.firstIndex(of: "--say"),
                  arguments.indices.contains(index + 1) {
            // `--model fast|standard|deep` overrides the tier for this run,
            // which is how the latency budget gets compared across models.
            if let modelIndex = arguments.firstIndex(of: "--model"),
               arguments.indices.contains(modelIndex + 1),
               let tier = ModelTier(shortName: arguments[modelIndex + 1]) {
                appState.modelTier = tier
            }
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
