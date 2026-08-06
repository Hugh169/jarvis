import Foundation
import JarvisCore

/// Drives the HUD through a full turn with no audio, network, or tools.
/// Phases 2–4 replace this with the real pipeline; until then it's how the
/// interface gets exercised (and it doubles as a UI smoke test).
@MainActor
enum HUDDemo {
    static func runTurn(on appState: AppState) async {
        appState.beginSimulatedListening()

        let question = "Remind me to submit the physics prac at four, and what's the weather tomorrow?"
        for prefix in partials(of: question) {
            appState.transcript = prefix
            try? await Task.sleep(for: .milliseconds(90))
        }
        appState.transcriptIsPartial = false

        try? await Task.sleep(for: .milliseconds(350))
        await appState.engine.handle(.transcriptReady)

        // Claude takes a beat before its first tool call; the HUD shows
        // "Thinking…" in that window rather than an empty rail.
        try? await Task.sleep(for: .milliseconds(1200))

        let reminder = appState.beginActivity(toolName: "create_reminder")
        try? await Task.sleep(for: .milliseconds(260))
        let weather = appState.beginActivity(toolName: "get_weather")

        try? await Task.sleep(for: .milliseconds(500))
        appState.finishActivity(id: reminder, status: .succeeded)
        try? await Task.sleep(for: .milliseconds(240))
        appState.finishActivity(id: weather, status: .succeeded)

        try? await Task.sleep(for: .milliseconds(200))
        await appState.engine.handle(.speechStarted)

        let reply = "Reminder set for four. Tomorrow: nineteen degrees, showers clearing by midday."
        for prefix in partials(of: reply) {
            appState.replyText = prefix
            try? await Task.sleep(for: .milliseconds(28))
        }

        try? await Task.sleep(for: .milliseconds(400))
        appState.detailMarkdown = """
        **Tomorrow — Sydney**
        Showers, clearing · 19° / 12°
        Rain chance · 70%
        Reminder · 4:00 pm
        """

        try? await Task.sleep(for: .seconds(4))
        await appState.engine.handle(.speechFinished)
    }

    /// Demonstrates the confirmation gate without sending anything.
    static func runConfirmation(on appState: AppState) async {
        appState.beginSimulatedListening()
        appState.transcript = "Message Dad that I'll be late."
        appState.transcriptIsPartial = false
        await appState.engine.handle(.transcriptReady)

        let approved = await appState.requestConfirmation(
            ConfirmationRequest(
                toolName: "send_message",
                summary: "Send to Dad — \u{201C}Running late, sorry!\u{201D}",
                bundleIdentifier: "com.apple.MobileSMS",
                symbolName: "message",
                confirmVerb: "Send"
            )
        )

        await appState.engine.handle(.speechStarted)
        appState.replyText = approved ? "Sent." : "Left it alone."
        try? await Task.sleep(for: .seconds(3))
        await appState.engine.handle(.speechFinished)
    }

    /// Progressive prefixes on word boundaries, mimicking streamed output.
    private static func partials(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            current += (current.isEmpty ? "" : " ") + word
            result.append(current)
        }
        return result
    }
}
