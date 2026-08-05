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
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .none // fades are driven by HUDController
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
