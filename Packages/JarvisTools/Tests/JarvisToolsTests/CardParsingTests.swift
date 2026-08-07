import Testing
import Foundation
import JarvisCore
@testable import JarvisTools

/// The parser is deliberately forgiving: a block missing the fields its own
/// type needs is dropped, not fatal. Losing one row of a page is a far better
/// outcome than erroring and having the model read the answer aloud instead —
/// but "forgiving" has to stop short of putting nonsense on screen.
@Suite struct CardParsingTests {
    private func deck(_ blocks: JSONValue) -> CardDeck? {
        DisplayCardsTool.deck(from: .object(["title": .string("Paris"), "blocks": blocks]))
    }

    @Test func buildsFactsWhichAreTheCommonCase() throws {
        let result = try #require(deck([[
            "type": "facts",
            "facts": [
                ["label": "Country", "value": "France"],
                ["label": "Population", "value": "2.1 million"],
            ],
        ]]))
        #expect(result.title == "Paris")
        guard case .facts(let facts) = result.blocks[0].kind else {
            Issue.record("expected facts"); return
        }
        #expect(facts.map(\.label) == ["Country", "Population"])
    }

    /// A half-filled pair is worse than no pair — "Population: " reads as a
    /// missing answer rather than an omitted one.
    @Test func dropsIncompleteFacts() throws {
        let result = try #require(deck([[
            "type": "facts",
            "facts": [
                ["label": "Country", "value": "France"],
                ["label": "Population", "value": ""],
                ["label": "", "value": "orphan"],
            ],
        ]]))
        guard case .facts(let facts) = result.blocks[0].kind else {
            Issue.record("expected facts"); return
        }
        #expect(facts.count == 1)
    }

    @Test func aBlockWithNothingUsableIsDroppedEntirely() {
        #expect(deck([["type": "facts", "facts": []]]) == nil)
        #expect(deck([["type": "list", "items": []]]) == nil)
        #expect(deck([["type": "note", "text": ""]]) == nil)
    }

    @Test func oneBadBlockDoesntLoseTheGoodOnes() throws {
        let result = try #require(deck([
            ["type": "note"],                                   // no text
            ["type": "unheard_of"],                             // unknown type
            ["type": "note", "text": "Founded in the 3rd century BC."],
        ]))
        #expect(result.blocks.count == 1)
    }

    @Test func tableKeepsColumnsAndRows() throws {
        let result = try #require(deck([[
            "type": "table",
            "columns": ["City", "Population"],
            "rows": [["Paris", "2.1m"], ["Lyon", "0.5m"]],
        ]]))
        guard case .table(let columns, let rows) = result.blocks[0].kind else {
            Issue.record("expected table"); return
        }
        #expect(columns == ["City", "Population"])
        #expect(rows.count == 2)
    }

    // MARK: Map

    @Test func keepsARealCoordinate() throws {
        let result = try #require(deck([[
            "type": "map", "latitude": 48.8566, "longitude": 2.3522,
            "label": "Paris", "span_metres": 9000,
        ]]))
        guard case .map(let place) = result.blocks[0].kind else {
            Issue.record("expected map"); return
        }
        #expect(place.label == "Paris")
        #expect(place.spanMetres == 9000)
    }

    /// Null Island is the signature of a model filling in a required field it
    /// didn't know — showing it would put the Gulf of Guinea on screen.
    @Test func rejectsZeroAndOutOfRangeCoordinates() {
        #expect(deck([["type": "map", "latitude": 0, "longitude": 0]]) == nil)
        #expect(deck([["type": "map", "latitude": 91, "longitude": 2]]) == nil)
        #expect(deck([["type": "map", "latitude": 48, "longitude": -181]]) == nil)
        #expect(deck([["type": "map", "latitude": 48]]) == nil)
    }

    // MARK: Image

    /// The one block whose content is fetched from wherever the model says, so
    /// it gets the narrowest gate: https, and a real host.
    @Test func acceptsOnlyHTTPSImages() throws {
        #expect(deck([["type": "image", "url": "http://example.com/a.jpg"]]) == nil)
        #expect(deck([["type": "image", "url": "file:///etc/passwd"]]) == nil)
        #expect(deck([["type": "image", "url": "javascript:alert(1)"]]) == nil)
        #expect(deck([["type": "image", "url": "not a url at all"]]) == nil)

        let result = try #require(deck([[
            "type": "image", "url": "https://example.com/paris.jpg", "caption": "The Seine",
        ]]))
        guard case .image(let url, let caption) = result.blocks[0].kind else {
            Issue.record("expected image"); return
        }
        #expect(url.scheme == "https")
        #expect(caption == "The Seine")
    }

    // MARK: Envelope

    @Test func requiresATitleAndAtLeastOneBlock() {
        #expect(DisplayCardsTool.deck(from: .object(["blocks": [["type": "note", "text": "x"]]])) == nil)
        #expect(DisplayCardsTool.deck(from: .object(["title": .string("Paris")])) == nil)
        #expect(deck([]) == nil)
    }

    @Test func statNeedsAValueToBeWorthShowing() throws {
        #expect(deck([["type": "stat", "label": "Population"]]) == nil)
        let result = try #require(deck([[
            "type": "stat", "value": "2.1m", "label": "Population", "caption": "City proper",
        ]]))
        guard case .stat(let value, _, let caption) = result.blocks[0].kind else {
            Issue.record("expected stat"); return
        }
        #expect(value == "2.1m")
        #expect(caption == "City proper")
    }
}
