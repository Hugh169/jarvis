import SwiftUI
import JarvisCore

/// The HUD is the entire interface: what was heard, which apps are being
/// driven right now, and the spoken reply. Zones appear only when they have
/// content, and the panel grows downward from a fixed top edge.
struct HUDView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow

            if appState.pendingConfirmation != nil || !appState.activities.isEmpty {
                Divider().overlay(HUDTheme.hairline)
                toolRail
            }

            if !appState.replyText.isEmpty || appState.detailMarkdown != nil {
                Divider().overlay(HUDTheme.hairline)
                replySection
            }
        }
        .frame(width: HUDTheme.width, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(HUDTheme.scrim))
                .compositingGroup()
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .strokeBorder(HUDTheme.hairline)
        )
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: appState.activities)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: appState.replyText)
        // Report height so the panel can resize while keeping its top edge put.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            appState.hudContentHeight = height
        }
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: 13) {
            stateGlyph

            VStack(alignment: .leading, spacing: 3) {
                EyebrowLabel(text: appState.turnState == .listening ? "Listening" : "You said")
                Text(transcriptText)
                    .font(HUDTheme.body)
                    .foregroundStyle(appState.transcriptIsPartial ? HUDTheme.inkSecondary : HUDTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 20, alignment: .leading)
            }

            Spacer(minLength: 8)

            WaveformView(levels: appState.micLevels, isActive: appState.turnState == .listening)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
    }

    private var transcriptText: String {
        appState.transcript.isEmpty ? "…" : appState.transcript
    }

    private var stateGlyph: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))

            Image(systemName: glyphSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(glyphColor)
                .contentTransition(.symbolEffect(.replace))

            // Mic-hot ring, the one place red appears outside a failure.
            if appState.turnState == .listening {
                Circle()
                    .strokeBorder(HUDTheme.alert, lineWidth: 1.5)
                    .scaleEffect(1.22)
                    .opacity(0)
                    .transition(.identity)
            }
        }
        .frame(width: 34, height: 34)
    }

    private var glyphSymbol: String {
        switch appState.turnState {
        case .listening: "mic.fill"
        case .thinking: "circle.dotted"
        case .speaking: "speaker.wave.2.fill"
        case .idle: "waveform"
        }
    }

    private var glyphColor: Color {
        switch appState.turnState {
        case .listening: HUDTheme.alert
        case .thinking: HUDTheme.brass
        default: HUDTheme.ink
        }
    }

    // MARK: Tools

    private var toolRail: some View {
        VStack(alignment: .leading, spacing: 9) {
            EyebrowLabel(text: appState.pendingConfirmation != nil ? "Needs your go-ahead" : "Working")

            VStack(spacing: 7) {
                ForEach(appState.activities) { activity in
                    ToolChipView(activity: activity)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                if let request = appState.pendingConfirmation {
                    ConfirmationChipView(request: request) { approved in
                        appState.resolveConfirmation(approved: approved)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: Reply

    private var replySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            EyebrowLabel(text: "JARVIS")

            if !appState.replyText.isEmpty {
                Text(appState.replyText)
                    .font(HUDTheme.body)
                    .foregroundStyle(HUDTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail = appState.detailMarkdown {
                Divider()
                    .overlay(HUDTheme.hairline)
                    .padding(.top, 6)

                // Rendered directly rather than in a ScrollView: a scroll view
                // has no intrinsic content height, so inside this self-sizing
                // panel it collapses and the detail never appears. The panel is
                // meant to grow to fit anyway.
                Text(attributed(detail))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(HUDTheme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 13)
        .padding(.bottom, 15)
    }

    /// display_detail sends markdown; render what AttributedString supports and
    /// fall back to the raw text rather than showing nothing.
    private func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}
