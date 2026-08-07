import Testing
import Foundation
import JarvisTools
@testable import JarvisBrain

@Suite struct ServerToolTests {
    /// The dynamic-filtering variant is a 400 on Haiku, which is exactly the
    /// tier chosen for latency — so the version has to follow the model rather
    /// than be hardcoded.
    @Test func webSearchVersionFollowsTheModel() {
        #expect(ModelTier.fast.webSearchVersion == .basic)
        #expect(ModelTier.standard.webSearchVersion == .filtered)
        #expect(ModelTier.deep.webSearchVersion == .filtered)
    }

    @Test func webSearchDefinitionShape() throws {
        let tool = ServerTool.webSearch(version: .filtered, maxUses: 6)
        #expect(tool["type"]?.stringValue == "web_search_20260209")
        #expect(tool["name"]?.stringValue == "web_search")
        #expect(tool["max_uses"]?.numberValue == 6)
        #expect(tool["user_location"] == nil)
    }

    @Test func omitsOptionalFields() {
        let tool = ServerTool.webSearch(version: .basic)
        #expect(tool["type"]?.stringValue == "web_search_20250305")
        #expect(tool["max_uses"] == nil)
    }

    @Test func userLocationIsApproximate() {
        let tool = ServerTool.webSearch(
            version: .filtered,
            userLocation: .init(city: "Sydney", country: "AU", timezone: "Australia/Sydney")
        )
        let location = try? #require(tool["user_location"])
        #expect(location?["type"]?.stringValue == "approximate")
        #expect(location?["city"]?.stringValue == "Sydney")
        #expect(location?["country"]?.stringValue == "AU")
        #expect(location?["region"] == nil)
    }
}
