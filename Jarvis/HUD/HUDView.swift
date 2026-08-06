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

            if appState.pendingConfirmation != nil || !appState.activities.isEmpty
                || appState.turnState == .thinking {
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

            VStack(alignment: .leading, spacing: 5) {
                EyebrowLabel(text: appState.turnState == .listening ? "Listening" : "You said")
                Text(transcriptText)
                    .font(HUDTheme.body)
                    .foregroundStyle(appState.transcriptIsPartial ? HUDTheme.inkSecondary : HUDTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    // .topLeading, not .leading: a min-height box centres its
                    // content vertically, so a one-line transcript would sit
                    // lower than a two-line one and the gap under the label
                    // would change with how long you spoke.
                    .frame(minHeight: 20, alignment: .topLeading)
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

            // Mic-hot ring, the one place red appears outside a failure.
            if appState.turnState == .listening {
                PulsingRing()
            }

            Image(systemName: glyphSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(glyphColor)
                .contentTransition(.symbolEffect(.replace))
                // Every active state carries motion; a frozen glyph while
                // Claude is working reads as a hang.
                .symbolEffect(
                    .variableColor.iterative.dimInactiveLayers,
                    isActive: appState.turnState == .thinking || appState.turnState == .speaking
                )
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
                // Claude often thinks for a beat before calling anything; an
                // empty rail there reads as nothing happening.
                if appState.activities.isEmpty && appState.pendingConfirmation == nil {
                    Text("Thinking…")
                        .font(.system(size: 13))
                        .foregroundStyle(HUDTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }

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

    /// Expanding ring behind the mic glyph while the input is hot.
    private struct PulsingRing: View {
        @State private var expanded = false

        var body: some View {
            Circle()
                .strokeBorder(HUDTheme.alert, lineWidth: 1.5)
                .scaleEffect(expanded ? 1.34 : 0.88)
                .opacity(expanded ? 0 : 0.55)
                .animation(.easeOut(duration: 1.7).repeatForever(autoreverses: false), value: expanded)
                .onAppear { expanded = true }
                .accessibilityHidden(true)
        }
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
