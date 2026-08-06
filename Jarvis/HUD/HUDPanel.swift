import AppKit

/// Borderless floating panel that appears over full-screen apps without
/// stealing focus from whatever the user is doing.
final class HUDPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        // The window draws no shadow of its own. Its content now includes a
        // soft ambient halo, and macOS derives the window shadow from content
        // alpha — which turned the halo's gradient into ragged black shapes
        // around the panel. Shadows are drawn in SwiftUI instead.
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .none // fades are driven by HUDController
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
