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
    let activity: ToolActivity

    var body: some View {
        HStack(spacing: 10) {
            ToolIconView(bundleIdentifier: activity.bundleIdentifier, symbolName: activity.symbolName)

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title)
                    .font(.system(size: 13))
                    .foregroundStyle(HUDTheme.ink)
                Text(activity.toolName)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(HUDTheme.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                elapsedText
                StatusDot(status: activity.status)
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
        switch activity.status {
        case .failed(let reason):
            Text(reason)
                .font(HUDTheme.mono)
                .foregroundStyle(HUDTheme.alert)
                .lineLimit(1)
        case .awaitingConfirmation:
            Text("waiting")
                .font(HUDTheme.mono)
                .foregroundStyle(HUDTheme.brass)
        case .running:
            // Ticks while the tool works; frozen once it finishes.
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text(Self.format(activity.elapsed(now: context.date)))
                    .font(HUDTheme.mono)
                    .foregroundStyle(HUDTheme.inkSecondary)
                    .monospacedDigit()
            }
        case .succeeded:
            Text(Self.format(activity.elapsed()))
                .font(HUDTheme.mono)
                .foregroundStyle(HUDTheme.inkSecondary)
                .monospacedDigit()
        }
    }

    private var accessibilityDescription: String {
        switch activity.status {
        case .running: "\(activity.title), running"
        case .awaitingConfirmation: "\(activity.title), waiting for your confirmation"
        case .succeeded: "\(activity.title), done in \(Self.format(activity.elapsed()))"
        case .failed(let reason): "\(activity.title), failed: \(reason)"
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
        case .running, .awaitingConfirmation: HUDTheme.brass
        case .succeeded: HUDTheme.ok
        case .failed: HUDTheme.alert
        }
    }
}

/// Destructive or outward-facing action blocked on a yes/no. Deliberately the
/// only place in the HUD with real buttons.
struct ConfirmationChipView: View {
    let request: ConfirmationRequest
    let onDecision: (Bool) -> Void

    /// Approve stays inert briefly after the chip appears, so a click already
    /// travelling towards whatever was underneath can't authorise anything.
    /// Cancel is live immediately — the safe answer never needs protecting.
    @State private var armed = false
    private static let armingDelay: Duration = .milliseconds(450)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ToolIconView(bundleIdentifier: request.bundleIdentifier, symbolName: request.symbolName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(HUDTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(request.toolName) · requires confirmation")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(HUDTheme.inkTertiary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                // No `.defaultAction` on approve. It made approval the window's
                // default button, so a stray Return authorised a destructive
                // action — and the HUD is a non-activating panel the user never
                // deliberately focuses. Approval must be a click.
                Button(request.confirmVerb) { onDecision(true) }
                    .buttonStyle(HUDButtonStyle(prominent: true))
                    .disabled(!armed)
                    .opacity(armed ? 1 : 0.5)
                Button("Cancel") { onDecision(false) }
                    .buttonStyle(HUDButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(11)
        .background(HUDTheme.brass.opacity(0.10), in: RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous)
                .strokeBorder(HUDTheme.brass.opacity(0.34))
        )
        .task {
            armed = false
            try? await Task.sleep(for: Self.armingDelay)
            armed = true
        }
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
                    .fill(prominent ? HUDTheme.brass.opacity(configuration.isPressed ? 0.75 : 0.9)
                                    : Color.white.opacity(configuration.isPressed ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(prominent ? .clear : Color.white.opacity(0.14))
            )
            .foregroundStyle(prominent ? Color(red: 0.14, green: 0.09, blue: 0.02) : HUDTheme.ink)
            .contentShape(Rectangle())
    }
}
