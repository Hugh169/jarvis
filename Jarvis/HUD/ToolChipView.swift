import SwiftUI
import JarvisCore

/// Icon for a tool: the real app icon when the tool drives an app, otherwise
/// the SF Symbol fallback.
struct ToolIconView: View {
    let bundleIdentifier: String?
    let symbolName: String

    var body: some View {
        Group {
            if let bundleIdentifier, let icon = AppIconLoader.icon(forBundleIdentifier: bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                    .overlay(
                        Image(systemName: symbolName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HUDTheme.inkSecondary)
                    )
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

struct ToolChipView: View {
    let group: ToolActivityGroup

    private var activity: ToolActivity { group.first }

    var body: some View {
        HStack(spacing: 10) {
            ToolIconView(bundleIdentifier: activity.bundleIdentifier, symbolName: activity.symbolName)

            // Title and nothing else. The tool name, the arguments and the
            // repeat count were all on the row at various points and all of it
            // read as noise — the title says what happened, the timing says how
            // long, and that is the whole of what a glance needs.
            //
            // Grouping still matters even with the count hidden: it is what
            // turns five travel lookups into one row instead of five. The
            // count and arguments both survive in the accessibility label.
            Text(activity.title)
                .font(.system(size: 13))
                .foregroundStyle(HUDTheme.ink)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                elapsedText
                StatusDot(status: group.status)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(HUDTheme.chipFill, in: RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous)
                .strokeBorder(HUDTheme.chipStroke)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var elapsedText: some View {
        switch group.status {
        case .failed(let reason):
            Text(reason)
                .font(HUDTheme.mono)
                .foregroundStyle(HUDTheme.alert)
                .lineLimit(1)
        case .awaitingConfirmation:
            Text("waiting")
                .font(HUDTheme.mono)
                .foregroundStyle(HUDTheme.confirm)
        case .running:
            // Ticks while the tool works; frozen once it finishes. A group
            // still running shows the wall clock of the one in flight.
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text(Self.format(activity.elapsed(now: context.date)))
                    .font(HUDTheme.mono)
                    .foregroundStyle(HUDTheme.inkSecondary)
                    .monospacedDigit()
            }
        case .succeeded:
            Text(Self.format(group.elapsed()))
                .font(HUDTheme.mono)
                .foregroundStyle(HUDTheme.inkSecondary)
                .monospacedDigit()
        }
    }

    private var accessibilityDescription: String {
        var name = group.count > 1 ? "\(activity.title), \(group.count) times" : activity.title
        // Carries what the row no longer shows, so a screen reader still gets
        // the destinations and queries the sighted view dropped.
        if let subtitle = group.subtitle { name += ", \(subtitle)" }
        return switch group.status {
        case .running: "\(name), running"
        case .awaitingConfirmation: "\(name), waiting for your confirmation"
        case .succeeded: "\(name), done in \(Self.format(group.elapsed()))"
        case .failed(let reason): "\(name), failed: \(reason)"
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        interval < 1 ? "\(Int(interval * 1000)) ms" : String(format: "%.1f s", interval)
    }
}

private struct StatusDot: View {
    let status: ToolActivity.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(pulses ? 0.35 : 1)
            .animation(
                pulses ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                value: pulses
            )
    }

    private var pulses: Bool { !status.isTerminal }

    private var color: Color {
        switch status {
        case .running: HUDTheme.accent
        case .awaitingConfirmation: HUDTheme.confirm
        case .succeeded: HUDTheme.ok
        case .failed: HUDTheme.alert
        }
    }
}

/// The decision, in the HUD. Everything happens in one panel — there is no
/// second window.
///
/// This is the only place in the HUD with real buttons, and the panel has to
/// accept clicks while it is up. That reopens a problem seen for real: the HUD
/// floats where app toolbars and address bars live, and clicks aimed at Safari
/// once landed on the approve button and authorised writes nobody meant. Three
/// things push back, and it is worth knowing which is which:
///
/// - **Approve waits 450ms after appearing.** Stops a click already in flight.
/// - **Approve also requires the pointer to rest here for 400ms.** A click on
///   its way to the window underneath arrives moments after the pointer does;
///   a person actually answering has read the thing first. This is the control
///   that does the most work, because it does not expire.
/// - **The buttons sit at the bottom of the panel**, furthest from the toolbar
///   strip the HUD overlaps.
///
/// Cancel has none of these. The safe answer never needs protecting, and
/// Escape — already a global hotkey while the HUD is up — declines too.
struct ConfirmationCardView: View {
    let request: ConfirmationRequest
    let onDecision: (Bool) -> Void

    @State private var settled = false
    @State private var hovering = false
    @State private var dwelled = false

    private static let settleDelay: Duration = .milliseconds(450)
    private static let dwellDelay: Duration = .milliseconds(400)

    private var armed: Bool { settled && dwelled }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ToolIconView(bundleIdentifier: request.bundleIdentifier, symbolName: request.symbolName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.summary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(HUDTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(request.toolName) · requires confirmation")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(HUDTheme.confirm)
                }
                Spacer(minLength: 0)
            }

            if !request.details.isEmpty {
                // `ViewThatFits` rather than a bare ScrollView: a ScrollView is
                // greedy and takes the whole cap whatever it holds, which put a
                // one-line script in a box of mostly empty space. Natural height
                // when the rows fit, scrolling only when they don't — and the
                // wheel does arrive here, because the panel accepts mouse
                // events while a decision is pending.
                ViewThatFits(in: .vertical) {
                    detailRows
                    ScrollView { detailRows }
                }
                .frame(maxHeight: 190)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
            }

            HStack(spacing: 7) {
                Button("Cancel") { onDecision(false) }
                    .buttonStyle(HUDButtonStyle(prominent: false))
                // No `.defaultAction`. It made approval the panel's default
                // button, so a stray Return authorised a destructive action —
                // and this is a non-activating panel the user never deliberately
                // focuses. Approval must be a deliberate click.
                Button(request.confirmVerb) { onDecision(true) }
                    .buttonStyle(HUDButtonStyle(prominent: true))
                    .disabled(!armed)
                    .opacity(armed ? 1 : 0.45)
            }
        }
        .padding(11)
        .background(HUDTheme.confirm.opacity(0.12), in: RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous)
                .strokeBorder(HUDTheme.confirm.opacity(0.40))
        )
        .onHover { inside in
            hovering = inside
            // Leaving resets the dwell: the pointer has to settle again, so a
            // sweep across the panel on the way somewhere else never arms it.
            if !inside { dwelled = false }
        }
        .task(id: hovering) {
            guard hovering else { return }
            try? await Task.sleep(for: Self.dwellDelay)
            if !Task.isCancelled { dwelled = true }
        }
        .task {
            settled = false
            try? await Task.sleep(for: Self.settleDelay)
            settled = true
        }
    }

    /// Shared by both branches of `ViewThatFits` so the fitting test and the
    /// scrolling fallback can't drift apart.
    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(request.details, id: \.label) { detail in
                VStack(alignment: .leading, spacing: 1) {
                    Text(detail.label)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(HUDTheme.inkTertiary)
                        .textCase(.uppercase)
                    Text(detail.value)
                        .font(.system(size: 12))
                        .foregroundStyle(HUDTheme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(9)
    }
}

private struct HUDButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? HUDTheme.accent.opacity(configuration.isPressed ? 0.78 : 1.0)
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
