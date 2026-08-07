import SwiftUI

/// Renders the block structure of markdown, not just its inline runs.
///
/// `AttributedString(markdown:)` handles bold and italic but discards block
/// structure — headings keep a `presentationIntent` that `Text` does nothing
/// with, so "## Your Week Ahead" rendered with its hashes showing. This walks
/// the lines itself and builds a view per block, using AttributedString only
/// for the inline emphasis inside each one.
///
/// Deliberately a subset: headings, bullets, numbered items, rules and
/// paragraphs. That is what the assistant actually emits, and a full markdown
/// engine would be a lot of surface for a pane that shows a dozen lines.
struct MarkdownBlocks: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level == 1 ? 13 : 12, weight: .semibold))
                .foregroundStyle(HUDTheme.ink)
                .padding(.top, 2)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(HUDTheme.accent.opacity(0.7))
                    .frame(width: 3.5, height: 3.5)
                    .offset(y: -3)
                Text(inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(HUDTheme.inkSecondary)

        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(number).")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HUDTheme.inkTertiary)
                    .monospacedDigit()
                Text(inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(HUDTheme.inkSecondary)

        case .rule:
            Divider().overlay(HUDTheme.hairline)

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 12))
                .foregroundStyle(HUDTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inline emphasis only — block syntax has already been stripped by the
    /// line parser, so there's nothing here for the parser to mangle.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    enum Block: Equatable {
        case heading(level: Int, String)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
        case rule
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.allSatisfy({ $0 == "-" }) && line.count >= 3 {
                blocks.append(.rule)
                continue
            }

            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    blocks.append(.heading(level: min(hashes, 3), text))
                    continue
                }
            }

            // "- item", "* item", and the en dash the assistant tends to use
            // when it is writing for a voice product.
            if let marker = ["- ", "* ", "• ", "– "].first(where: line.hasPrefix) {
                blocks.append(.bullet(String(line.dropFirst(marker.count))))
                continue
            }

            if let match = numberedItem(line) {
                blocks.append(.numbered(match.0, match.1))
                continue
            }

            // One line, one block — deliberately *not* markdown's soft-wrap
            // folding. The assistant writes a fact per line here ("Rain chance
            // · 70%"), and folding those into a paragraph runs them together
            // into a sentence that was never written.
            blocks.append(.paragraph(line))
        }

        return blocks
    }

    private static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}
