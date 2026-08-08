import AppKit
import SwiftUI
import Combine
import JarvisCore

/// Confirmations get their own focused window, deliberately not the HUD.
///
/// The HUD floats at top-centre, which is where app toolbars, tab bars and
/// address bars live, and it has to accept clicks to carry buttons. That
/// combination approved real writes during testing: clicks aimed at Safari
/// landed on the approve button. No arrangement of click-through and arming
/// delays fixes that, because the panel is in the wrong place and the user
/// never chose to interact with it.
///
/// A window centred on screen, which takes focus and can be answered from the
/// keyboard, makes the click unambiguous — it is the only thing under the
/// pointer, and it is there because a decision is genuinely pending.
@MainActor
final class ConfirmationWindowController {
    private unowned let appState: AppState
    private var window: NSWindow?
    private var observer: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        observer = appState.$pendingConfirmation
            .removeDuplicates()
            .sink { [weak self] request in
                guard let self else { return }
                if let request {
                    DebugLog.write("confirmation window presenting for \(request.toolName)")
                    self.present(request)
                } else {
                    self.dismiss()
                }
            }
    }

    private static let width: CGFloat = 460

    private func present(_ request: ConfirmationRequest) {
        let view = ConfirmationView(request: request) { [weak self] approved in
            self?.appState.resolveConfirmation(approved: approved)
        }

        let window = self.window ?? makeWindow()
        // `contentViewController`, not `contentView`: AppKit then sizes the
        // window from SwiftUI's intrinsic content. Setting `contentView` and
        // reading `fittingSize` sizes it before layout has run, which returns
        // zero and puts a 0×0 window on screen — present, focused, invisible.
        let host = NSHostingController(rootView: view)
        // The title bar is hidden and the content draws under it, so the safe
        // area it reserves is just dead space above the icon.
        host.safeAreaRegions = []
        window.contentViewController = host
        // Lay out before centring. `centre` divides by the window's width, and
        // straight after assignment that width is still zero — which put the
        // window's left edge exactly on the middle of the screen.
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        centre(window)

        // Order front before making key: a window that is not yet on screen
        // cannot become key, and skipping this leaves the buttons visible but
        // the keyboard pointed at whatever was in front.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func dismiss() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        // Hand focus back to whatever the user was actually working in. The
        // window took it unbidden, so returning it is part of the deal.
        NSApp.deactivate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(HUDTheme.panelCore)
        window.hasShadow = true
        // Above the HUD's `.floating`, so the two can never fight over which is
        // in front while a decision is pending.
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        // Nothing dismisses this except an answer. A stray ⌘W or a click on the
        // close button would leave the tool call suspended, so the buttons are
        // the only way out.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        return window
    }

    /// Centred on the screen the user is working on, and deliberately not at
    /// top-centre where the HUD lives.
    private func centre(_ window: NSWindow) {
        let screen = NSScreen.main
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            // Slightly above centre: the optical middle of a screen sits a
            // little high, and it keeps clear of a dock-height strip.
            y: visible.midY - size.height / 2 + visible.height * 0.08
        ))
    }
}

/// The decision itself. Dark like the rest of JARVIS, but a real window with
/// real focus — the one surface in the app that is allowed to interrupt.
struct ConfirmationView: View {
    let request: ConfirmationRequest
    let onDecision: (Bool) -> Void

    /// Approve stays inert briefly after the window appears. The window takes
    /// focus unbidden, so a click or keystroke already in flight towards
    /// whatever was in front must not be able to authorise anything. Cancel is
    /// live immediately — the safe answer never needs protecting.
    @State private var armed = false
    private static let armingDelay: Duration = .milliseconds(450)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ToolIconView(
                    bundleIdentifier: request.bundleIdentifier,
                    symbolName: request.symbolName
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.summary)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HUDTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(request.toolName) · needs your go-ahead")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HUDTheme.confirm)
                }
                Spacer(minLength: 0)
            }

            if !request.details.isEmpty {
                // Scrolls, unlike the HUD's detail pane: this window accepts
                // mouse events, so the wheel actually arrives. A long mail body
                // must be readable in full before it is approved.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(request.details, id: \.label) { detail in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(detail.label)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(HUDTheme.inkTertiary)
                                    .textCase(.uppercase)
                                Text(detail.value)
                                    .font(.system(size: 13))
                                    .foregroundStyle(HUDTheme.ink)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous)
                        .fill(HUDTheme.chipFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous)
                        .strokeBorder(HUDTheme.chipStroke)
                )
            }

            HStack(spacing: 9) {
                Spacer(minLength: 0)
                Button("Cancel") { onDecision(false) }
                    .buttonStyle(ConfirmationButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                // ⌘Return, not Return. The window appears unbidden and takes
                // focus, so a Return the user was already typing into their own
                // app must not authorise anything — the same in-flight-input
                // problem as the click, one device over.
                Button(request.confirmVerb) { onDecision(true) }
                    .buttonStyle(ConfirmationButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!armed)
                    .opacity(armed ? 1 : 0.5)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(HUDTheme.panelCore)
        .environment(\.colorScheme, .dark)
        .task {
            armed = false
            try? await Task.sleep(for: Self.armingDelay)
            armed = true
        }
    }
}

private struct ConfirmationButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 7)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent
                          ? HUDTheme.accent.opacity(configuration.isPressed ? 0.78 : 1.0)
                          : Color.white.opacity(configuration.isPressed ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(prominent ? .clear : Color.white.opacity(0.14))
            )
            .foregroundStyle(prominent ? HUDTheme.onAccent : HUDTheme.ink)
            .contentShape(Rectangle())
    }
}
