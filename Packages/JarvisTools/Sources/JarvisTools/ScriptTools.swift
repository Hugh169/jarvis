import Foundation

/// Runs an arbitrary AppleScript — the escape hatch for everything that has no
/// specific tool.
///
/// This is the most dangerous tool in the app and there is no way to make it
/// otherwise: AppleScript can drive any scriptable application on this Mac. The
/// controls are what they are, and it is worth being precise about which are
/// real and which are not:
///
/// - **The confirmation window is the only real barrier.** The script is shown
///   in full, so approving it is an informed decision — but it is the user's
///   judgement doing the work, not the code's.
/// - **The description tells the model to prefer specific tools.** That is an
///   instruction, not an enforcement.
/// - **A timeout and an output cap** stop a runaway script from hanging the turn
///   or flooding the context window. Those are enforced.
///
/// What is *not* covered: a script approved once is not remembered, but nothing
/// stops the model proposing a script assembled from text it read in an email.
/// See "Memory is a write surface" in CLAUDE.md — the same untrusted-input
/// problem, with a much larger blast radius.
public struct RunAppleScriptTool: JarvisTool {
    public static let name = "run_applescript"
    public static let description = """
        Runs an AppleScript on this Mac. This is an escape hatch: use it only \
        when no specific tool does the job, and prefer the specific tool every \
        time one exists. The user is shown the exact script and must approve it \
        before it runs, so write it to be read — short, and obvious about what \
        it touches.
        """
    public static let requiresConfirmation = true
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "script": ["type": "string", "description": "The AppleScript source."],
        ],
        "required": ["script"],
    ]

    /// A script that hasn't finished in this long is not going to. The turn is
    /// blocked behind it, so the ceiling matters more than the odd slow script.
    static let timeout: Duration = .seconds(30)
    /// Output beyond this is truncated. It goes into the context window, and a
    /// script that prints a whole file would otherwise cost the rest of the turn.
    static let outputLimit = 8_000

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let script = input["script"]?.stringValue,
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .error("run_applescript needs a script.") }

        return await Self.runOSAScript(script)
    }

    static func runOSAScript(_ script: String) async -> ToolResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        // The script arrives on stdin rather than as `-e` arguments: a
        // multi-line script would otherwise need one `-e` per line, and a long
        // one can exceed the argument length limit.
        process.arguments = ["-"]

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .error("Couldn't run osascript: \(error.localizedDescription)")
        }

        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()

        // Kill it if it overruns. An AppleScript can block indefinitely on a
        // dialog in another app, and the turn is suspended behind it.
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        let stdout = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()

        let text = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            // terminate() lands as an uncaught signal, which is the timeout
            // rather than a script error — worth distinguishing, since the
            // model's next move differs.
            if process.terminationReason == .uncaughtSignal {
                return .error("The script was still running after \(timeout) and was stopped.")
            }
            return .error(failure.isEmpty ? "The script failed." : truncate(failure))
        }
        return ToolResult(content: text.isEmpty ? "Done." : truncate(text))
    }

    static func truncate(_ text: String) -> String {
        guard text.count > outputLimit else { return text }
        return String(text.prefix(outputLimit)) + "\n… (truncated)"
    }
}
