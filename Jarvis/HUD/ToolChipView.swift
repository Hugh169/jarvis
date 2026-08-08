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

/// Reports that something is waiting on a decision. Carries no buttons on
/// purpose: the answer is given in `ConfirmationWindowController`'s window, so
/// the HUD never has to accept a click and can stay click-through even while a
/// destructive action is pending. That is the whole point of the split — a
/// panel sitting on top of Safari's toolbar is not a place to put consent.
struct ConfirmationNoticeView: View {
    let request: ConfirmationRequest

    var body: some View {
        HStack(spacing: 10) {
            ToolIconView(bundleIdentifier: request.bundleIdentifier, symbolName: request.symbolName)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(HUDTheme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(request.toolName) · answer in the window")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(HUDTheme.inkTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(HUDTheme.confirm.opacity(0.12), in: RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous)
                .strokeBorder(HUDTheme.confirm.opacity(0.40))
        )
    }
}
