import SwiftUI
import MapKit
import JarvisCore

/// A visual answer, in the HUD's own language: cyan for anything live or
/// numeric, monospace for data, the same chip fill and hairline as everywhere
/// else. Nothing here introduces a colour or a shape the panel doesn't already
/// use — a card should look like it grew out of the HUD rather than landing in
/// it from a design system.
struct CardsView: View {
    let deck: CardDeck

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            EyebrowLabel(text: deck.title)

            ForEach(deck.blocks) { block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: CardBlock) -> some View {
        switch block.kind {
        case .facts(let facts): FactsBlock(facts: facts)
        case .stat(let value, let label, let caption):
            StatBlock(value: value, label: label, caption: caption)
        case .list(let items): ListBlock(items: items)
        case .table(let columns, let rows): TableBlock(columns: columns, rows: rows)
        case .note(let text): NoteBlock(text: text)
        case .map(let place): MapBlock(place: place)
        case .image(let url, let caption): ImageBlock(url: url, caption: caption)
        }
    }
}

/// Label left, value right, hairline between. The value carries the emphasis
/// because it is the part being looked up.
private struct FactsBlock: View {
    let facts: [Fact]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 { Divider().overlay(HUDTheme.hairline) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(fact.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(HUDTheme.inkTertiary)
                    Spacer(minLength: 10)
                    Text(fact.value)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(HUDTheme.ink)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 11)
        .cardSurface()
    }
}

private struct StatBlock: View {
    let value: String
    let label: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .foregroundStyle(HUDTheme.accent)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(HUDTheme.inkSecondary)
            if let caption {
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(HUDTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .cardSurface()
    }
}

private struct ListBlock: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(HUDTheme.accent.opacity(0.7))
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: -3)
                    Text(item)
                        .font(.system(size: 12))
                        .foregroundStyle(HUDTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .cardSurface()
    }
}

/// Monospaced throughout, because the only reason to put something in a table
/// is to compare down a column.
private struct TableBlock: View {
    let columns: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            row(columns, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Divider().overlay(HUDTheme.hairline)
                row(cells, isHeader: false)
            }
        }
        .padding(.horizontal, 11)
        .cardSurface()
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(cells.prefix(columns.count).enumerated()), id: \.offset) { index, cell in
                Text(cell)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isHeader ? HUDTheme.inkTertiary : HUDTheme.ink)
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

/// The one block with a coloured edge. Cyan, not amber — amber in this HUD
/// means "needs your go-ahead" and must not start meaning "noteworthy".
private struct NoteBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle()
                .fill(HUDTheme.accent.opacity(0.8))
                .frame(width: 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(HUDTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MapBlock: View {
    let place: MapPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MapSnapshotView(place: place)
            if let label = place.label {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(HUDTheme.inkTertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
            }
        }
        .cardSurface()
        .clipShape(RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous))
    }
}

private struct ImageBlock: View {
    let url: URL
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImageView(url: url)
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(HUDTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
            }
        }
        .cardSurface()
        .clipShape(RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous))
    }
}

private extension View {
    /// The same fill and stroke as a tool chip, so cards and chips read as the
    /// same material.
    func cardSurface() -> some View {
        background(
            HUDTheme.chipFill,
            in: RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HUDTheme.chipRadius, style: .continuous)
                .strokeBorder(HUDTheme.chipStroke)
        )
    }
}
