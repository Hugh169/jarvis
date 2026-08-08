import Foundation
import JarvisCore
import JarvisTools
import JarvisBrain
import JarvisConnectors
import JarvisMemory

/// Owns the tool registry and executes calls on behalf of a turn: confirmation
/// gating, concurrent execution, dry-run, and the audit trail.
@MainActor
final class ToolCoordinator {
    private unowned let appState: AppState
    private var registry = ToolRegistry()

    /// Spec §4: bail out rather than loop forever if the model keeps calling
    /// tools without settling on an answer.
    static let maxIterations = 8

    /// A server-side search can exhaust its own iteration budget and come back
    /// `pause_turn`, which we resume. Bounded for the same reason as above.
    static let maxContinuations = 5

    init(appState: AppState) {
        self.appState = appState
        registerAll()
    }

    var toolDefinitions: [JSONValue] { registry.apiDefinitions }
    var toolNames: [String] { registry.toolNames }

    /// The full tool block for a request: everything JARVIS executes, plus any
    /// server-side tools the model may call directly.
    ///
    /// Order is load-bearing — the tool block is the front of the cached prompt
    /// prefix, so it must be byte-identical between turns. The server tool goes
    /// last, and its version depends on the model, but changing model
    /// invalidates the cache anyway.
    func apiTools(for tier: ModelTier, webSearch: Bool) -> [JSONValue] {
        var definitions = registry.apiDefinitions
        if webSearch {
            definitions.append(ServerTool.webSearch(
                version: tier.webSearchVersion,
                maxUses: 6
            ))
        }
        return definitions
    }

    private func registerAll() {
        // Order is stable and matters: the tool block is part of the cached
        // prompt prefix, so it must be byte-identical between turns.
        try? registry.register(CreateReminderTool())
        try? registry.register(ListRemindersTool())
        try? registry.register(CompleteReminderTool())
        try? registry.register(CreateEventTool())
        try? registry.register(ListEventsTool { schedule in
            await MainActor.run { AppState.shared.schedule = schedule }
        })
        try? registry.register(GetWeatherTool())
        try? registry.register(WhereAmITool())
        try? registry.register(TravelTimeTool())
        try? registry.register(DirectionsTool())
        try? registry.register(NearbyTool())
        try? registry.register(OpenAppTool())
        try? registry.register(QuitAppTool())
        try? registry.register(ListRunningAppsTool())
        try? registry.register(SearchFilesTool())
        try? registry.register(ReadFileTool())
        try? registry.register(WriteFileTool())
        try? registry.register(ClipboardReadTool())
        try? registry.register(ClipboardWriteTool())
        try? registry.register(SetVolumeTool())
        try? registry.register(OpenURLTool())
        try? registry.register(RunShortcutTool())
        try? registry.register(RunAppleScriptTool())

        // Memory. Registered unconditionally for the same reason as the Google
        // tools: the tool block is the front of the cached prompt prefix, so it
        // has to be byte-identical between turns. If the database can't be
        // opened they say so at execute time.
        try? registry.register(RememberTool())
        try? registry.register(RecallTool())
        try? registry.register(ForgetTool())

        // Registered whether or not an account is connected: the tool block is
        // the front of the cached prompt prefix, so it has to be identical
        // between turns, and appearing only after a connection would invalidate
        // the cache mid-session. Unconnected, they return an error telling the
        // user where to connect.
        try? registry.register(ListGoogleEventsTool())
        try? registry.register(CreateGoogleEventTool())
        try? registry.register(SearchMailTool())
        try? registry.register(ReadMailTool())
        try? registry.register(DraftMailTool())
        try? registry.register(SendMailTool())

        let appState = self.appState
        try? registry.register(DisplayDetailTool { markdown in
            await MainActor.run { appState.detailMarkdown = markdown }
        })
        try? registry.register(DisplayCardsTool { deck in
            await MainActor.run { appState.cards = deck }
        })
        try? registry.register(DisplayScheduleTool { schedule in
            await MainActor.run { appState.schedule = schedule }
        })
        try? registry.register(RequestConfirmationTool { summary, verb in
            await appState.requestConfirmation(
                ConfirmationRequest(
                    toolName: "request_confirmation",
                    summary: summary,
                    symbolName: "exclamationmark.shield",
                    confirmVerb: verb
                )
            )
        })
    }

    /// Runs the model's tool calls and returns the `tool_result` blocks.
    ///
    /// Independent calls run concurrently — the model routinely asks for two or
    /// three at once and running them serially wastes seconds of a budget
    /// measured in hundreds of milliseconds. Results are reassembled in request
    /// order because the API pairs them by id.
    /// Named rather than a tuple: the compiler's region-based isolation checker
    /// can't reason about destructuring a tuple out of a task group.
    private struct IndexedResult: Sendable {
        let index: Int
        let block: JSONValue
    }

    func execute(_ toolUses: [Anthropic.ToolUse]) async -> [JSONValue] {
        // Child tasks are non-isolated; `runOne` is @MainActor so each hops back
        // on its own. Annotating them @MainActor instead trips the compiler's
        // region-based isolation checker.
        var collected: [IndexedResult] = []
        await withTaskGroup(of: IndexedResult.self) { group in
            for (index, use) in toolUses.enumerated() {
                group.addTask {
                    IndexedResult(index: index, block: await self.runOne(use))
                }
            }
            for await item in group {
                collected.append(item)
            }
        }
        // The API pairs results to calls by id, but keeping request order makes
        // the audit log and the HUD read in the order the model asked.
        return collected.sorted { $0.index < $1.index }.map(\.block)
    }

    /// The one argument worth putting on a chip.
    ///
    /// Five `travel_time_to` chips in a row are indistinguishable without it —
    /// you can see that five things happened and nothing about what. Bulk
    /// arguments (markdown, file bodies) are deliberately not candidates.
    static func subtitle(for use: Anthropic.ToolUse) -> String? {
        guard case .object(let fields) = use.input else { return nil }
        let identifying = [
            "destination", "query", "location", "name", "title",
            "to", "app_name", "app", "url", "path", "shortcut",
        ]
        for key in identifying {
            if let value = fields[key]?.stringValue, !value.isEmpty {
                return String(value.prefix(64))
            }
        }
        return nil
    }

    private func runOne(_ use: Anthropic.ToolUse) async -> JSONValue {
        let activityID = appState.beginActivity(
            toolName: use.name, subtitle: Self.subtitle(for: use)
        )
        let started = Date.now
        let needsConfirmation = registry.requiresConfirmation(use.name)

        // Confirmation gate, before anything happens.
        if needsConfirmation {
            appState.markActivityAwaitingConfirmation(id: activityID)
            DebugLog.write("confirmation gate opened for \(use.name)")
            let approved = await appState.requestConfirmation(
                Self.confirmationRequest(for: use)
            )
            DebugLog.write("confirmation gate for \(use.name) resolved: \(approved)")
            guard approved else {
                appState.finishActivity(id: activityID, status: .failed("declined"))
                await AuditLog.shared.record(
                    tool: use.name, arguments: use.input, outcome: .declined,
                    detail: "User declined.", requiredConfirmation: true, confirmed: false,
                    duration: Date.now.timeIntervalSince(started)
                )
                return Anthropic.toolResultBlock(
                    id: use.id,
                    content: "The user declined this. Do not retry; acknowledge briefly.",
                    isError: false
                )
            }
        }

        // Dry run: report what would happen without touching anything.
        if appState.dryRunEnabled {
            appState.finishActivity(id: activityID, status: .succeeded)
            await AuditLog.shared.record(
                tool: use.name, arguments: use.input, outcome: .dryRun,
                detail: "Dry run.", requiredConfirmation: needsConfirmation,
                confirmed: needsConfirmation ? true : nil,
                duration: Date.now.timeIntervalSince(started)
            )
            return Anthropic.toolResultBlock(
                id: use.id,
                content: "Dry-run mode: this would have run but nothing was changed.",
                isError: false
            )
        }

        do {
            let result = try await registry.execute(name: use.name, input: use.input)
            appState.finishActivity(
                id: activityID,
                status: result.isError ? .failed("failed") : .succeeded
            )
            await AuditLog.shared.record(
                tool: use.name, arguments: use.input,
                outcome: result.isError ? .failed : .succeeded,
                detail: result.content, requiredConfirmation: needsConfirmation,
                confirmed: needsConfirmation ? true : nil,
                duration: Date.now.timeIntervalSince(started)
            )
            return Anthropic.toolResultBlock(
                id: use.id, content: result.content, isError: result.isError
            )
        } catch {
            let message = error.localizedDescription
            appState.finishActivity(id: activityID, status: .failed("failed"))
            await AuditLog.shared.record(
                tool: use.name, arguments: use.input, outcome: .failed,
                detail: message, requiredConfirmation: needsConfirmation,
                confirmed: needsConfirmation ? true : nil,
                duration: Date.now.timeIntervalSince(started)
            )
            return Anthropic.toolResultBlock(id: use.id, content: message, isError: true)
        }
    }

    /// Shows the arguments, not just the tool name — approving "write_file"
    /// blind is not consent.
    ///
    /// The arguments go in `details` rather than being joined onto the summary
    /// and clipped at 80 characters each. That clipping was survivable while
    /// this rendered as one line in the HUD; it is not now that the window has
    /// room, and it was actively dangerous for `send_mail`, where the body is
    /// the part you most need to read.
    private static func confirmationRequest(for use: Anthropic.ToolUse) -> ConfirmationRequest {
        let descriptor = ToolPresentation.descriptor(for: use.name)
        return ConfirmationRequest(
            toolName: use.name,
            summary: descriptor.title,
            details: ConfirmationDetails.rows(from: use.input),
            bundleIdentifier: descriptor.bundleIdentifier,
            symbolName: descriptor.symbolName,
            confirmVerb: Self.verb(for: use.name)
        )
    }

    private static func verb(for toolName: String) -> String {
        switch toolName {
        case "write_file": "Write"
        case "quit_app": "Quit"
        case "run_shortcut", "run_applescript": "Run"
        case "send_message", "compose_mail": "Send"
        case "forget": "Forget"
        default: "Confirm"
        }
    }
}
