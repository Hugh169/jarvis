import AppKit
import SwiftUI
import Combine

@MainActor
final class HUDController {
    private static let topInset: CGFloat = 24
    private static let fadeDuration: TimeInterval = 0.18

    private unowned let appState: AppState
    private var panel: HUDPanel?
    private var heightObserver: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        // HUDView reports its intrinsic height; the panel follows it.
        heightObserver = appState.$hudContentHeight
            .removeDuplicates()
            .sink { [weak self] height in
                self?.resize(to: height)
            }
    }

    func show() {
        let panel = ensurePanel()
        if !panel.isVisible {
            position(panel, height: panel.frame.height)
        }
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
        let height = max(appState.hudContentHeight, 84)
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: HUDTheme.width, height: height))
        let host = NSHostingView(rootView: HUDView().environmentObject(appState))
        host.frame = NSRect(x: 0, y: 0, width: HUDTheme.width, height: height)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.alphaValue = 0
        self.panel = panel
        return panel
    }

    /// Grows and shrinks from the top edge. NSWindow frames are bottom-left
    /// origin, so height changes must move the origin to keep the top still.
    private func resize(to height: CGFloat) {
        guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func position(_ panel: HUDPanel, height: CGFloat) {
        // Top-centre of the screen the user is working on.
        let screen = NSScreen.main
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - HUDTheme.width / 2,
            y: visible.maxY - height - Self.topInset
        ))
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
