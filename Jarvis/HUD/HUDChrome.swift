import SwiftUI

/// Ambient decoration for the panel: reticle corners, a slow rotating halo, a
/// breathing border, and a scan sweep while the model works.
///
/// This is chrome, not state. The corners and halo look identical whatever
/// JARVIS is doing — only the sweep is tied to a state, and even that is
/// reinforcing the glyph rather than being the sole signal. Anything that
/// carries meaning on its own belongs in the content, not here.
enum HUDChrome {}

// MARK: - Reticle corners

/// Four L-shaped marks just inside the panel edge.
struct ReticleCorners: View {
    var inset: CGFloat = 8
    var length: CGFloat = 14
    var lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            corner(.topLeading)
            corner(.topTrailing)
            corner(.bottomLeading)
            corner(.bottomTrailing)
        }
        .foregroundStyle(HUDTheme.accentGlow.opacity(0.8))
        .shadow(color: HUDTheme.accentGlow.opacity(0.8), radius: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func corner(_ alignment: Alignment) -> some View {
        CornerBracket(alignment: alignment, radius: 4)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: length, height: length)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(inset)
    }
}

/// One bracket: two edges meeting at a rounded outer corner.
private struct CornerBracket: Shape {
    let alignment: Alignment
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = radius

        switch alignment {
        case .topLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                              control: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case .topTrailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        default:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

// MARK: - Ambient halo

/// The breathing cyan glow around the panel.
///
/// Built from stacked shadows rather than a blurred shape. `.blur()` needs
/// pixels beyond the layer edge to sample, and in a transparent borderless
/// window there are none — a blurred halo renders as a hard rectangle with
/// ragged edges instead of soft light. Shadows composite cleanly against
/// transparency, and the reference's glow is `box-shadow` anyway.
///
/// The reference also rotates a conic gradient behind the panel. That is the
/// one part not reproduced: every way of doing it here relies on blurring a
/// gradient, which hits the same problem. At 14s per revolution it read as a
/// slow brightness shift, which the breath below already gives.
///
/// `TimelineView` drives the breath rather than a repeating animation, so it
/// stops dead when the HUD is hidden instead of animating a window nobody sees.
struct AmbientHalo: View {
    var isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 3.2s breath, matching the reference's floatGlow.
            let breath = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi / 3.2))

            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius + 2, style: .continuous)
                .strokeBorder(HUDTheme.accentGlow.opacity(0.55), lineWidth: 1.5)
                .shadow(color: HUDTheme.accentGlow.opacity(0.55), radius: 18)
                .shadow(color: HUDTheme.accentGlow.opacity(0.30), radius: 40)
                .padding(-2)
                .opacity(isActive ? breath : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Scan sweep

/// A band of light crossing the panel while the model is working. Reinforces
/// the spinning glyph; it is never the only indication that something is
/// happening.
struct ScanSweep: View {
    var isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { context in
            GeometryReader { proxy in
                let period = 2.2
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let width = proxy.size.width * 0.4
                let travel = proxy.size.width + width * 2

                LinearGradient(
                    colors: [.clear, HUDTheme.accent.opacity(0.10), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width)
                .offset(x: -width + travel * phase)
                // Fade in and out at the edges rather than popping.
                .opacity(sweepOpacity(phase))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .opacity(isActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }

    private func sweepOpacity(_ phase: Double) -> Double {
        switch phase {
        case ..<0.15: phase / 0.15
        case 0.85...: (1 - phase) / 0.15
        default: 1
        }
    }
}
