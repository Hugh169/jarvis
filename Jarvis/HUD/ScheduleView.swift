import SwiftUI
import JarvisCore

/// A day drawn rather than described.
///
/// Time runs down a gutter on the left against a continuous rail; each event is
/// a node on it, and the gap between two nodes carries the travel leg. The
/// shape of the day — back-to-back, or an hour of nothing, or two things at
/// once — is meant to be legible before any of the words are read.
struct ScheduleView: View {
    let schedule: Schedule

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EyebrowLabel(text: schedule.title)
                .padding(.bottom, 10)

            ForEach(Array(schedule.items.enumerated()), id: \.element.id) { index, item in
                // The leg belongs above the event it leads to, and the first
                // event has nothing to travel from.
                if index > 0, let minutes = item.travelMinutes {
                    TravelLeg(minutes: minutes, mode: item.travelMode)
                }
                EventRow(item: item, isLast: index == schedule.items.count - 1)
            }
        }
    }
}

private struct EventRow: View {
    let item: ScheduleItem
    let isLast: Bool

    private static let gutter: CGFloat = 62

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(item.time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(item.clashes ? HUDTheme.confirm : HUDTheme.inkSecondary)
                .monospacedDigit()
                .frame(width: Self.gutter, alignment: .leading)
                .padding(.top, 2)

            Rail(filled: !isLast, accent: item.clashes)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(HUDTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.clashes {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(HUDTheme.confirm)
                            .help("Overlaps another event")
                    }
                }
                if let location = item.location {
                    Text(location)
                        .font(.system(size: 11))
                        .foregroundStyle(HUDTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 11)
            .padding(.bottom, isLast ? 0 : 12)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.time), \(item.title)"
            + (item.location.map { ", at \($0)" } ?? "")
            + (item.clashes ? ", clashes with another event" : "")
        )
    }
}

/// The node and the line below it. Drawn rather than composed from shapes so
/// the line meets the node exactly at its edge at any row height.
private struct Rail: View {
    let filled: Bool
    let accent: Bool

    var body: some View {
        Canvas { canvas, size in
            let centre = CGPoint(x: size.width / 2, y: 7)
            let colour = accent ? HUDTheme.confirm : HUDTheme.accent

            if filled {
                var line = Path()
                line.move(to: CGPoint(x: centre.x, y: centre.y + 5))
                line.addLine(to: CGPoint(x: centre.x, y: size.height))
                canvas.stroke(line, with: .color(HUDTheme.accent.opacity(0.28)), lineWidth: 1.5)
            }

            let node = CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8)
            canvas.fill(Path(ellipseIn: node), with: .color(colour))
            canvas.fill(
                Path(ellipseIn: node.insetBy(dx: 2.4, dy: 2.4)),
                with: .color(HUDTheme.panelCore)
            )
        }
        .frame(width: 11)
        .accessibilityHidden(true)
    }
}

/// The gap between two events, carrying how long it takes to cross it.
private struct TravelLeg: View {
    let minutes: Int
    let mode: TravelDepiction?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: 62)

            // Dashed, so a leg reads as distinct from the solid rail between
            // an event and the next.
            Canvas { canvas, size in
                var line = Path()
                line.move(to: CGPoint(x: size.width / 2, y: 0))
                line.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                canvas.stroke(
                    line,
                    with: .color(HUDTheme.accent.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [2, 3])
                )
            }
            .frame(width: 11, height: 22)

            HStack(spacing: 5) {
                Image(systemName: mode?.symbolName ?? "arrow.down")
                    .font(.system(size: 9))
                Text("\(minutes) min")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(HUDTheme.inkTertiary)
            .padding(.leading, 11)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(minutes) minutes\(mode.map { " \($0.rawValue)" } ?? "")")
    }
}
