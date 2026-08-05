import AppKit
import SwiftUI

@MainActor
final class HUDController {
    private static let size = NSSize(width: 460, height: 120)
    private static let topInset: CGFloat = 24
    private static let fadeDuration: TimeInterval = 0.18

    private unowned let appState: AppState
    private var panel: HUDPanel?

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
        fade(panel, to: 1)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        fade(panel, to: 0) {
            panel.orderOut(nil)
        }
    }

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }
        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        let host = NSHostingView(rootView: HUDView().environmentObject(appState))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        panel.alphaValue = 0
        self.panel = panel
        return panel
    }

    private func position(_ panel: HUDPanel) {
        // Top-centre of the screen the user is working on (keyboard focus,
        // falling back to the screen under the mouse).
        let screen = NSScreen.main
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.maxY - Self.size.height - Self.topInset
        )
        panel.setFrameOrigin(origin)
    }

    private func fade(_ panel: HUDPanel, to alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            completion?()
        }
    }
}
