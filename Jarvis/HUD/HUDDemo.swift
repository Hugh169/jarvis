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

    /// The turn that broke the layout: a long dictated prompt, one tool called
    /// five times over, and a day's worth of detail. Deterministic, so the
    /// crowded case can be looked at without waiting on a real model.
    static func runSchedule(on appState: AppState) async {
        appState.beginSimulatedListening()

        let question = "tell me about my upcoming week, summarise emails, calendar info, "
            + "and plan my travel to and from events tomorrow so im where i need to be ontime"
        for prefix in partials(of: question) {
            appState.transcript = prefix
            try? await Task.sleep(for: .milliseconds(35))
        }
        appState.transcriptIsPartial = false
        await appState.engine.handle(.transcriptReady)
        try? await Task.sleep(for: .milliseconds(700))

        let calendar = appState.beginActivity(toolName: "list_events")
        try? await Task.sleep(for: .milliseconds(200))
        appState.finishActivity(id: calendar, status: .succeeded)

        let located = appState.beginActivity(toolName: "where_am_i")
        try? await Task.sleep(for: .milliseconds(300))
        appState.finishActivity(id: located, status: .succeeded)

        let mail = appState.beginActivity(toolName: "search_mail", subtitle: "is:unread newer_than:7d")
        try? await Task.sleep(for: .milliseconds(400))
        appState.finishActivity(id: mail, status: .succeeded)

        // Five in a row — the case that used to be five identical rows.
        for destination in ["Reformer Classic", "Annie's work", "Ned's soccer", "Netball courts", "Vaucluse"] {
            let leg = appState.beginActivity(toolName: "travel_time_to", subtitle: destination)
            try? await Task.sleep(for: .milliseconds(160))
            appState.finishActivity(id: leg, status: .succeeded)
        }

        await appState.engine.handle(.speechStarted)
        let reply = "Tomorrow is tight: you're out by half six, and netball clashes with Ned's kickoff."
        for prefix in partials(of: reply) {
            appState.replyText = prefix
            try? await Task.sleep(for: .milliseconds(26))
        }

        appState.schedule = Schedule(
            title: "Tomorrow — Friday 8 August",
            items: [
                .init(time: "6:30 am", title: "Leave home", location: "Warriewood"),
                .init(time: "7:00 am", title: "Reformer Classic", location: "Mona Vale",
                      travelMinutes: 12, travelMode: .driving),
                .init(time: "9:00 am", title: "Annie — Priceline shift", location: "Warringah Mall",
                      travelMinutes: 18, travelMode: .driving),
                .init(time: "11:15 am", title: "Netball game 1", location: "Manly Vale",
                      travelMinutes: 9, travelMode: .driving, clashes: true),
                .init(time: "11:30 am", title: "Ned — soccer kickoff", location: "Cromer Park",
                      clashes: true),
                .init(time: "5:00 pm", title: "Dinner", location: "Vaucluse",
                      travelMinutes: 47, travelMode: .driving),
            ]
        )

        try? await Task.sleep(for: .seconds(8))
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
