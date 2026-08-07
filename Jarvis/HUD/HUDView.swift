import SwiftUI
import JarvisCore

/// The HUD is the entire interface: what was heard, which apps are being
/// driven right now, and the spoken reply. Zones appear only when they have
/// content, and the panel grows downward from a fixed top edge.
struct HUDView: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow

            if appState.pendingConfirmation != nil || !appState.activities.isEmpty
                || appState.turnState == .thinking {
                Divider().overlay(HUDTheme.hairline)
                toolRail
            }

            if showsReply {
                Divider().overlay(HUDTheme.hairline)
                replySection
            }
        }
        .frame(width: HUDTheme.width, alignment: .leading)
        // Never let the panel squeeze its own content. The window's height
        // follows this view's reported height, so while it catches up the
        // proposal can be shorter than the content needs — and without this
        // SwiftUI compresses, which is what put the "Working" label on top of
        // a long transcript.
        .fixedSize(horizontal: false, vertical: true)
        .background {
            let shape = RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(HUDTheme.scrim))
                .compositingGroup()
                .shadow(color: .black.opacity(0.50), radius: 24, y: 12)
                // The wide outer bloom, straight from the reference's box-shadow.
                .shadow(color: HUDTheme.accentGlow.opacity(0.22), radius: 28)
                .shadow(color: HUDTheme.accentGlow.opacity(0.12), radius: 50)
        }
        .overlay(
            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .strokeBorder(HUDTheme.accent.opacity(0.40))
        )
        // Sweep is clipped to the panel; the halo deliberately isn't.
        .overlay(ScanSweep(isActive: appState.turnState == .thinking))
        .overlay(ReticleCorners())
        .clipShape(RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous))
        .background(AmbientHalo(isActive: appState.turnState != .idle))
        // Room for the halo to bleed into — without it the window clips the glow.
        .padding(HUDTheme.glowPadding)
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
                EyebrowLabel(text: eyebrowText)

                if appState.isComposing {
                    TextField("Type your message…", text: $appState.composedText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(HUDTheme.body)
                        .foregroundStyle(HUDTheme.ink)
                        .tint(HUDTheme.accent)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                        .onSubmit { appState.submitComposed() }
                        .onAppear { composerFocused = true }
                        .frame(minHeight: 20, alignment: .topLeading)
                } else {
                    Text(transcriptText)
                        .font(HUDTheme.body)
                        .foregroundStyle(appState.transcriptIsPartial ? HUDTheme.inkSecondary : HUDTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        // A long dictated prompt otherwise pushes everything
                        // that matters — the tools and the answer — off the
                        // bottom of the screen. You just said it; three lines
                        // is enough to confirm it was heard correctly.
                        .lineLimit(3)
                        .truncationMode(.tail)
                        // .topLeading, not .leading: a min-height box centres its
                        // content vertically, so a one-line transcript would sit
                        // lower than a two-line one and the gap under the label
                        // would change with how long you spoke.
                        .frame(minHeight: 20, alignment: .topLeading)
                }
            }

            Spacer(minLength: 8)

            WaveformView(
                levels: appState.micLevels,
                isActive: appState.turnState == .listening && !appState.isComposing
            )
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
    }

    private var eyebrowText: String {
        if appState.isComposing { return "Type to JARVIS" }
        return appState.turnState == .listening ? "Listening" : "You said"
    }

    private var transcriptText: String {
        appState.transcript.isEmpty ? "…" : appState.transcript
    }

    private var stateGlyph: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))

            // Mic-hot ring — not while typing, when the mic is shut.
            if appState.turnState == .listening && !appState.isComposing {
                PulsingRing()
            }

            glyph
        }
        .frame(width: 34, height: 34)
    }

    /// The working glyph spins continuously rather than pulsing — matches the
    /// reference and reads as activity at a glance.
    @ViewBuilder
    private var glyph: some View {
        if appState.turnState == .thinking {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Image(systemName: "circle.dotted")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HUDTheme.accent)
                    .rotationEffect(.degrees((t / 2.4).truncatingRemainder(dividingBy: 1) * 360))
            }
        } else {
            Image(systemName: glyphSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(glyphColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                              isActive: appState.turnState == .speaking)
        }
    }

    private var glyphSymbol: String {
        guard !appState.isComposing else { return "keyboard" }
        return switch appState.turnState {
        case .listening: "mic.fill"
        case .thinking: "circle.dotted"
        case .speaking: "speaker.wave.2.fill"
        case .idle: "waveform"
        }
    }

    private var glyphColor: Color {
        switch appState.turnState {
        // Cyan now carries listening too — in this palette red is reserved for
        // a failure, so a hot mic no longer borrows it.
        case .listening: HUDTheme.accent
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

                // Grouped: a turn that plans a day fires travel_time_to once
                // per leg, and five identical chips is five rows of vertical
                // space saying one thing.
                ForEach(ToolActivityGroup.group(appState.activities)) { group in
                    ToolChipView(group: group)
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

    /// The reply is spoken, not written. Printing it too made the panel a
    /// transcript of its own audio — and the model's throat-clearing on the way
    /// to an answer is much easier to ignore when heard than when set in type
    /// under a heading.
    ///
    /// The exception is a silent JARVIS: with no voice configured there is
    /// nothing to hear, and a HUD that shows neither the answer nor a way to
    /// read it is simply broken.
    private var isMute: Bool { appState.selectedVoiceID == nil }

    private var showsReply: Bool {
        appState.schedule != nil
            || appState.cards != nil
            || appState.detailMarkdown != nil
            || (isMute && !appState.replyText.isEmpty)
    }

    private var replySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            EyebrowLabel(text: "JARVIS")

            if isMute, !appState.replyText.isEmpty {
                Text(appState.replyText)
                    .font(HUDTheme.body)
                    .foregroundStyle(HUDTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let cards = appState.cards {
                Divider()
                    .overlay(HUDTheme.hairline)
                    .padding(.top, 6)

                boundedDetail {
                    CardsView(deck: cards)
                }
            }

            if let schedule = appState.schedule {
                Divider()
                    .overlay(HUDTheme.hairline)
                    .padding(.top, 6)

                boundedDetail {
                    ScheduleView(schedule: schedule)
                }
            }

            if let detail = appState.detailMarkdown {
                Divider()
                    .overlay(HUDTheme.hairline)
                    .padding(.top, 6)

                boundedDetail {
                    MarkdownBlocks(markdown: detail)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 13)
        .padding(.bottom, 15)
    }

    /// Detail is rendered at full height, never scrolled.
    ///
    /// A scroll view here cannot work: the panel is `ignoresMouseEvents` so
    /// that clicks aimed at whatever is underneath aren't stolen by a window
    /// sitting where toolbars live — and that makes it scroll-through too. The
    /// wheel never reaches the HUD. Making it reachable would mean accepting
    /// mouse events, which is exactly the behaviour the click-through rule
    /// exists to prevent.
    @ViewBuilder
    private func boundedDetail<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
    }

    /// Expanding ring behind the mic glyph while the input is hot.
    private struct PulsingRing: View {
        @State private var expanded = false

        var body: some View {
            Circle()
                .strokeBorder(HUDTheme.accent, lineWidth: 1.5)
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
