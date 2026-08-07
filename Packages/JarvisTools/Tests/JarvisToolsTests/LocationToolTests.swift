import Testing
import Foundation
@testable import JarvisTools

/// Covers the parts that don't need a location fix: the model's free-text mode
/// argument, and the phrasing of anything spoken aloud.
@Suite struct LocationToolTests {
    @Test func modeDefaultsToDriving() {
        #expect(TravelMode.parse(nil) == .driving)
        #expect(TravelMode.parse("") == .driving)
        #expect(TravelMode.parse("drive") == .driving)
        // Anything unrecognised drives rather than failing the turn.
        #expect(TravelMode.parse("hovercraft") == .driving)
    }

    /// The model doesn't always send the enum value it was given; it sends what
    /// the user said.
    @Test func modeAcceptsWhatPeopleActuallySay() {
        #expect(TravelMode.parse("walking") == .walking)
        #expect(TravelMode.parse("on foot") == .walking)
        #expect(TravelMode.parse("Walk") == .walking)
        #expect(TravelMode.parse("transit") == .transit)
        #expect(TravelMode.parse("public transport") == .transit)
        #expect(TravelMode.parse("train") == .transit)
    }

    /// This text is spoken, so it must read as speech — no "1 minutes",
    /// no "0 hours 7 minutes", no decimals.
    @Test func durationsReadAsSpeech() {
        #expect(SpokenDuration.describe(20) == "less than a minute")
        #expect(SpokenDuration.describe(60) == "1 minute")
        #expect(SpokenDuration.describe(1_380) == "23 minutes")
        #expect(SpokenDuration.describe(3_600) == "1 hour")
        #expect(SpokenDuration.describe(5_400) == "1 hour 30 minutes")
        #expect(SpokenDuration.describe(7_260) == "2 hours 1 minute")
    }

    @Test func durationRoundsToTheNearestMinute() {
        #expect(SpokenDuration.describe(119) == "1 minute")
        #expect(SpokenDuration.describe(121) == "2 minutes")
    }

    @Test func toolsDeclareUsableSchemas() throws {
        #expect(TravelTimeTool.name == "travel_time_to")
        #expect(TravelTimeTool.inputSchema["required"]?[0]?.stringValue == "destination")
        #expect(NearbyTool.inputSchema["required"]?[0]?.stringValue == "query")
        // Nothing here changes anything on the machine, so nothing should be
        // sitting behind the confirmation gate.
        #expect(WhereAmITool.requiresConfirmation == false)
        #expect(TravelTimeTool.requiresConfirmation == false)
        #expect(DirectionsTool.requiresConfirmation == false)
        #expect(NearbyTool.requiresConfirmation == false)
    }

    @Test func missingArgumentsFailCleanly() async throws {
        let result = try await TravelTimeTool().execute(.object([:]))
        #expect(result.isError)
        let nearby = try await NearbyTool().execute(.object(["query": .string("")]))
        #expect(nearby.isError)
    }
}
