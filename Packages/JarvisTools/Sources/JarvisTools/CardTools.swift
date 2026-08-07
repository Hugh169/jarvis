import Foundation
import JarvisCore

/// The general visual answer: one tool, many block types.
///
/// Separate display tools per shape were the obvious design and the wrong one —
/// the model has to choose, and it reliably chooses none of them. Here it makes
/// one call and composes the page.
public struct DisplayCardsTool: JarvisTool {
    public static let name = "display_cards"
    public static let description = """
        Put a visual answer on screen: facts, figures, lists, comparisons, \
        maps and photos.

        Call this for any question worth looking at as well as hearing — a \
        place, a person, a product, a comparison, anything with numbers or \
        properties. Build the page from blocks and put the substance there; \
        say one or two sentences aloud and let the screen carry the rest. \
        Never read a list of facts out loud.

        Blocks: facts (label/value pairs — the most useful by far), stat (one \
        headline number), list, table, note (one line worth pulling out), map \
        (give real coordinates), image (an https URL of a real photo you have \
        actually seen in a search result — never guess one).
        """

    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Heading, e.g. \"Paris\"."],
            "blocks": [
                "type": "array",
                "description": "In the order they should be read down the panel.",
                "items": [
                    "type": "object",
                    "properties": [
                        "type": [
                            "type": "string",
                            "enum": ["facts", "stat", "list", "table", "note", "map", "image"],
                        ],
                        "facts": [
                            "type": "array",
                            "description": "For type=facts.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": ["type": "string"],
                                    "value": ["type": "string"],
                                ],
                                "required": ["label", "value"],
                            ],
                        ],
                        "value": ["type": "string", "description": "For type=stat: the number."],
                        "label": ["type": "string", "description": "For type=stat: what it measures."],
                        "caption": ["type": "string", "description": "For type=stat or image."],
                        "items": [
                            "type": "array",
                            "description": "For type=list.",
                            "items": ["type": "string"],
                        ],
                        "columns": [
                            "type": "array",
                            "description": "For type=table.",
                            "items": ["type": "string"],
                        ],
                        "rows": [
                            "type": "array",
                            "description": "For type=table: one array of cells per row.",
                            "items": ["type": "array", "items": ["type": "string"]],
                        ],
                        "text": ["type": "string", "description": "For type=note."],
                        "latitude": ["type": "number", "description": "For type=map."],
                        "longitude": ["type": "number", "description": "For type=map."],
                        "span_metres": [
                            "type": "number",
                            "description": "For type=map: how much ground to show. A city ~8000, a building ~300.",
                        ],
                        "url": ["type": "string", "description": "For type=image: an https URL."],
                    ],
                    "required": ["type"],
                ],
            ],
        ],
        "required": ["title", "blocks"],
    ]

    private let present: @Sendable (CardDeck) async -> Void

    public init(present: @escaping @Sendable (CardDeck) async -> Void) {
        self.present = present
    }

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        let deck = Self.deck(from: input)
        guard let deck, !deck.isEmpty else {
            return .error("No usable blocks — every one was missing its content.")
        }
        await present(deck)
        return ToolResult(
            content: "On screen: \(deck.blocks.count) block(s). "
                + "Say one or two sentences; don't read it out."
        )
    }

    /// Lenient by design. A block missing the fields its own type needs is
    /// dropped rather than failing the call — losing one row of a page is a
    /// far better outcome than the model getting an error and reading the
    /// whole answer aloud instead.
    public static func deck(from input: JSONValue) -> CardDeck? {
        guard let title = input["title"]?.stringValue, !title.isEmpty,
              case .array(let raw)? = input["blocks"] else { return nil }
        let blocks = raw.compactMap(block(from:))
        return blocks.isEmpty ? nil : CardDeck(title: title, blocks: blocks)
    }

    static func block(from entry: JSONValue) -> CardBlock? {
        guard let type = entry["type"]?.stringValue else { return nil }
        switch type {
        case "facts":
            guard case .array(let items)? = entry["facts"] else { return nil }
            let facts = items.compactMap { item -> Fact? in
                guard let label = item["label"]?.stringValue,
                      let value = item["value"]?.stringValue,
                      !label.isEmpty, !value.isEmpty else { return nil }
                return Fact(label: label, value: value)
            }
            return facts.isEmpty ? nil : CardBlock(kind: .facts(facts))

        case "stat":
            guard let value = entry["value"]?.stringValue, !value.isEmpty,
                  let label = entry["label"]?.stringValue else { return nil }
            return CardBlock(kind: .stat(
                value: value, label: label, caption: entry["caption"]?.stringValue
            ))

        case "list":
            guard case .array(let items)? = entry["items"] else { return nil }
            let lines = items.compactMap(\.stringValue).filter { !$0.isEmpty }
            return lines.isEmpty ? nil : CardBlock(kind: .list(lines))

        case "table":
            guard case .array(let columnValues)? = entry["columns"],
                  case .array(let rowValues)? = entry["rows"] else { return nil }
            let columns = columnValues.compactMap(\.stringValue)
            let rows = rowValues.compactMap { row -> [String]? in
                guard case .array(let cells) = row else { return nil }
                return cells.map { $0.stringValue ?? "" }
            }
            return columns.isEmpty || rows.isEmpty
                ? nil
                : CardBlock(kind: .table(columns: columns, rows: rows))

        case "note":
            guard let text = entry["text"]?.stringValue, !text.isEmpty else { return nil }
            return CardBlock(kind: .note(text))

        case "map":
            guard let latitude = entry["latitude"]?.numberValue,
                  let longitude = entry["longitude"]?.numberValue else { return nil }
            let pin = MapPlace(
                latitude: latitude,
                longitude: longitude,
                label: entry["label"]?.stringValue,
                spanMetres: entry["span_metres"]?.numberValue ?? 4_000
            )
            return pin.isPlausible ? CardBlock(kind: .map(pin)) : nil

        case "image":
            // https only, and only a real URL. This is the one block whose
            // content is fetched from wherever the model says, so it gets the
            // narrowest gate of the lot.
            guard let raw = entry["url"]?.stringValue,
                  let url = URL(string: raw), url.scheme == "https",
                  url.host?.isEmpty == false else { return nil }
            return CardBlock(kind: .image(url: url, caption: entry["caption"]?.stringValue))

        default:
            return nil
        }
    }
}
