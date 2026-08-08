import Foundation
import Testing
@testable import JarvisTools

/// These run real `osascript`. The scripts are arithmetic and string work only —
/// nothing that targets another application, so nothing that needs an
/// automation permission grant.
@Suite("AppleScript tool")
struct ScriptToolsTests {
    @Test("It is gated behind confirmation — this is the whole safety story")
    func requiresConfirmation() {
        #expect(RunAppleScriptTool.requiresConfirmation)
    }

    @Test("A script's result comes back as the tool result")
    func returnsResult() async throws {
        let result = try await RunAppleScriptTool().execute(["script": "return 6 * 7"])
        #expect(result.isError == false)
        #expect(result.content == "42")
    }

    /// Note `return ""` rather than something like `set x to 1`: AppleScript
    /// implicitly returns the last statement's value, so most "silent" scripts
    /// do in fact print something.
    @Test("A script that returns nothing still reports success")
    func reportsSilentSuccess() async throws {
        let result = try await RunAppleScriptTool().execute(["script": #"return """#])
        #expect(result.isError == false)
        #expect(result.content == "Done.")
    }

    @Test("Multi-line scripts work, which is why the source goes in on stdin")
    func handlesMultiLine() async throws {
        let script = """
            set total to 0
            repeat with n from 1 to 4
                set total to total + n
            end repeat
            return total
            """
        let result = try await RunAppleScriptTool().execute(["script": .string(script)])
        #expect(result.content == "10")
    }

    @Test("A failing script reports the error rather than a false success")
    func reportsFailure() async throws {
        let result = try await RunAppleScriptTool().execute(
            ["script": "this is not applescript"]
        )
        #expect(result.isError)
    }

    @Test("An empty or whitespace script is rejected before osascript runs")
    func rejectsEmptyScript() async throws {
        for script in ["", "   ", "\n"] {
            let result = try await RunAppleScriptTool().execute(["script": .string(script)])
            #expect(result.isError)
            #expect(result.content.contains("needs a script"))
        }
    }

    @Test("Missing script argument is an error, not a crash")
    func rejectsMissingArgument() async throws {
        #expect(try await RunAppleScriptTool().execute(["nothing": "here"]).isError)
    }

    @Test("Output past the cap is truncated, so it can't eat the context window")
    func truncatesLongOutput() {
        let long = String(repeating: "a", count: RunAppleScriptTool.outputLimit + 500)
        let truncated = RunAppleScriptTool.truncate(long)
        #expect(truncated.count < long.count)
        #expect(truncated.hasSuffix("… (truncated)"))
    }

    @Test("Output under the cap is left alone")
    func leavesShortOutputAlone() {
        #expect(RunAppleScriptTool.truncate("short") == "short")
    }

    @Test("Quotes and unicode survive the round trip through stdin")
    func handlesAwkwardText() async throws {
        let result = try await RunAppleScriptTool().execute(
            ["script": #"return "it's a \"test\" — ünïcode""#]
        )
        #expect(result.content == #"it's a "test" — ünïcode"#)
    }
}
