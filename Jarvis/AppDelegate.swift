import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeys: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon. LSUIElement covers the bundled build;
        // this covers `swift run` in dev mode.
        NSApp.setActivationPolicy(.accessory)
        hotkeys = HotkeyManager(appState: AppState.shared)
    }
}
