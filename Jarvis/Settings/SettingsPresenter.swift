import AppKit
import SwiftUI

/// Owns the Settings window directly instead of using SwiftUI's `Settings`
/// scene.
///
/// The scene approach does not work here. This app is `LSUIElement` with an
/// `.accessory` activation policy, and in that configuration neither
/// `SettingsLink` nor `showSettingsWindow:` produces a window at all — the
/// selector fires and nothing appears, so Settings is simply unreachable.
/// Hosting `SettingsView` in an `NSWindow` we control sidesteps the whole
/// problem and makes the behaviour obvious.
///
/// The app still becomes a regular one while the window is open, so it can take
/// focus and appear in the app switcher, and drops back to `.accessory` on
/// close so no Dock icon lingers.
@MainActor
final class SettingsPresenter: NSObject, NSWindowDelegate {
    private static let shared = SettingsPresenter()

    private var window: NSWindow?

    static func show() { shared.present() }

    private func present() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "JARVIS Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            // Back to a menu-bar-only app.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
