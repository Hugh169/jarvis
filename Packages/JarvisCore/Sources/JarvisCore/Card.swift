import Foundation

/// A visual answer, composed from primitives.
///
/// The lesson from `display_schedule` is that the model will not reliably pick
/// between several display tools — so there is one tool, and it builds a page
/// out of blocks. Fewer decisions, and the shape of the answer can be whatever
/// the question needs.
public struct CardDeck: Sendable, Equatable {
    public let title: String
    public let blocks: [CardBlock]

    public init(title: String, blocks: [CardBlock]) {
        self.title = title
        self.blocks = blocks
    }

    public var isEmpty: Bool { blocks.isEmpty }
}

public struct CardBlock: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// Deliberately small. Every block here has to earn a place in a panel
    /// that floats over someone's work — a chart library's worth of options
    /// would mostly produce things too fiddly to read at a glance.
    public enum Kind: Sendable, Equatable {
        /// The workhorse: label/value pairs. "Country · France".
        case facts([Fact])
        /// One number worth looking at, with its unit and a line of context.
        case stat(value: String, label: String, caption: String?)
        case list([String])
        case table(columns: [String], rows: [[String]])
        /// A single line pulled out of the flow — a caveat, a headline.
        case note(String)
        case map(MapPlace)
        case image(url: URL, caption: String?)
    }
}

public struct Fact: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let label: String
    public let value: String

    public init(id: UUID = UUID(), label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Somewhere on a map. Rendered as a still image rather than a live map view:
/// the HUD is a floating panel nobody can pan or zoom, and a snapshot costs
/// nothing to keep on screen.
public struct MapPlace: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let label: String?
    /// How much ground to show. A city wants kilometres, a restaurant wants
    /// hundreds of metres.
    public let spanMetres: Double

    public init(latitude: Double, longitude: Double, label: String?, spanMetres: Double = 4_000) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
        self.spanMetres = spanMetres
    }

    /// Coordinates outside these bounds aren't a place, they're a mistake —
    /// usually a model filling a required field it didn't know the answer to.
    public var isPlausible: Bool {
        (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
            // Null Island: the signature of a zero-filled guess.
            && !(latitude == 0 && longitude == 0)
    }
}
