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

    private var mouseObserver: AnyCancellable?
    private var composeObserver: AnyCancellable?
    /// Displays can be added, removed or resized while the HUD is hidden.
    private var screenObserver: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState
        // HUDView reports its intrinsic height; the panel follows it.
        heightObserver = appState.$hudContentHeight
            .removeDuplicates()
            .sink { [weak self] height in
                self?.resize(to: height)
            }

        // The panel floats over everything at top-centre, which is exactly
        // where app toolbars and address bars live. It is click-through while
        // merely showing status, so clicks reach whatever is underneath — but
        // it must accept them while a confirmation is up or while typing.
        //
        // Everything happens in this one panel, confirmations included, so a
        // click aimed at the window below can still land on the approve button.
        // `ConfirmationCardView` carries the mitigations; see its comment for
        // which are real.
        composeObserver = appState.$isComposing
            .removeDuplicates()
            .sink { [weak self] composing in
                guard let self, let panel = self.panel else { return }
                panel.acceptsTyping = composing
                panel.ignoresMouseEvents = !composing && self.appState.pendingConfirmation == nil
                if composing, panel.isVisible {
                    self.makeKeyIfComposing(panel)
                }
            }

        mouseObserver = appState.$pendingConfirmation
            .map { $0 == nil }
            .removeDuplicates()
            .sink { [weak self] clickThrough in
                guard let self else { return }
                self.panel?.ignoresMouseEvents = clickThrough && !self.appState.isComposing
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.layout(panel)
            }
        }
    }

    func show() {
        let panel = ensurePanel()
        // Always re-lay-out, not just when hidden. The old code anchored to the
        // panel's previous top edge, so if the display changed resolution while
        // the HUD was away it reappeared wherever the stale frame happened to
        // land — bottom-left, on a smaller screen.
        layout(panel)
        panel.orderFrontRegardless()
        makeKeyIfComposing(panel)
        fade(panel, to: 1)
    }

    /// A panel only receives keystrokes once it is key, and it can only become
    /// key once it is on screen — so this has to happen after ordering front,
    /// not when `acceptsTyping` is first set. Without it the text field is
    /// visible but every keystroke goes to whatever app was in front.
    private func makeKeyIfComposing(_ panel: HUDPanel) {
        guard appState.isComposing else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        fade(panel, to: 0) {
            panel.orderOut(nil)
        }
    }

    /// The window is wider than the panel: HUDView pads itself so the ambient
    /// halo has somewhere to bleed, and anything outside the window is clipped.
    private static var windowWidth: CGFloat { HUDTheme.width + HUDTheme.glowPadding * 2 }

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }
        let height = max(appState.hudContentHeight, 84 + HUDTheme.glowPadding * 2)
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: height))
        let host = NSHostingView(rootView: HUDView().environmentObject(appState))
        host.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: height)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.alphaValue = 0
        // Click-through until something needs an answer.
        panel.ignoresMouseEvents = appState.pendingConfirmation == nil && !appState.isComposing
        panel.acceptsTyping = appState.isComposing
        self.panel = panel
        return panel
    }

    private func resize(to height: CGFloat) {
        guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        layout(panel, height: height)
    }

    /// Computes the frame from the current screen every time, rather than
    /// nudging the previous one. Anchoring to the old frame accumulated drift
    /// and broke completely when the display geometry changed.
    private func layout(_ panel: HUDPanel, height: CGFloat? = nil) {
        let target = height ?? max(appState.hudContentHeight, 84 + HUDTheme.glowPadding * 2)

        // The screen the user is working on: keyboard focus first, then the one
        // under the pointer.
        let screen = NSScreen.main
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        // The glow padding is transparent, so the visible panel still sits at
        // the intended inset rather than being pushed down by it.
        let frame = NSRect(
            x: visible.midX - Self.windowWidth / 2,
            y: visible.maxY - target - Self.topInset + HUDTheme.glowPadding,
            width: Self.windowWidth,
            height: target
        )
        panel.setFrame(frame, display: true, animate: false)
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
