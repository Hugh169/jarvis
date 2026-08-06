import SwiftUI

/// Live input meter. Phase 2 feeds real RMS from the audio tap; until then the
/// levels array simply stays empty and the bars idle.
struct WaveformView: View {
    var levels: [Float]
    var isActive: Bool

    private let barCount = 11

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isActive)) { context in
            Canvas { canvas, size in
                let barWidth: CGFloat = 3.4
                let gap = (size.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
                let seconds = context.date.timeIntervalSinceReferenceDate

                for index in 0..<barCount {
                    let amplitude = amplitude(at: index, seconds: seconds)
                    let height = max(3, CGFloat(amplitude) * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * (barWidth + gap),
                        y: (size.height - height) / 2,
                        width: barWidth,
                        height: height
                    )
                    canvas.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(HUDTheme.alert.opacity(0.55 + Double(amplitude) * 0.45))
                    )
                }
            }
        }
        .frame(width: 62, height: 22)
        .opacity(isActive ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: isActive)
        .accessibilityHidden(true)
    }

    private func amplitude(at index: Int, seconds: TimeInterval) -> Float {
        guard isActive else { return 0.1 }
        if !levels.isEmpty {
            // Newest sample at the right edge.
            let offset = levels.count - barCount + index
            if offset >= 0 { return min(1, max(0.1, levels[offset] * 3)) }
            return 0.1
        }
        // No audio yet: a gentle shaped idle so the meter reads as live.
        let envelope = sin(Double(index) / Double(barCount) * .pi)
        let motion = sin(seconds * 6 + Double(index) * 0.7) * 0.5 + 0.5
        return Float(0.15 + envelope * motion * 0.7)
    }
}
