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
        let arguments = CommandLine.arguments
        if arguments.contains("--demo-turn") {
            appState.runDemoTurn()
        } else if arguments.contains("--demo-confirmation") {
            appState.runDemoConfirmation()
        }
    }
}
