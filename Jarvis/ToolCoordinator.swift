import Foundation
import JarvisCore
import JarvisTools
import JarvisBrain

/// Owns the tool registry and executes calls on behalf of a turn: confirmation
/// gating, concurrent execution, dry-run, and the audit trail.
@MainActor
final class ToolCoordinator {
    private unowned let appState: AppState
    private var registry = ToolRegistry()

    /// Spec §4: bail out rather than loop forever if the model keeps calling
    /// tools without settling on an answer.
    static let maxIterations = 8

    init(appState: AppState) {
        self.appState = appState
        registerAll()
    }

    var toolDefinitions: [JSONValue] { registry.apiDefinitions }
    var toolNames: [String] { registry.toolNames }

    private func registerAll() {
        // Order is stable and matters: the tool block is part of the cached
        // prompt prefix, so it must be byte-identical between turns.
        try? registry.register(CreateReminderTool())
        try? registry.register(ListRemindersTool())
        try? registry.register(CompleteReminderTool())
        try? registry.register(CreateEventTool())
        try? registry.register(ListEventsTool())
        try? registry.register(GetWeatherTool())
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

        let appState = self.appState
        try? registry.register(DisplayDetailTool { markdown in
            await MainActor.run { appState.detailMarkdown = markdown }
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

    private func runOne(_ use: Anthropic.ToolUse) async -> JSONValue {
        let activityID = appState.beginActivity(toolName: use.name)
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
    private static func confirmationRequest(for use: Anthropic.ToolUse) -> ConfirmationRequest {
        let descriptor = ToolPresentation.descriptor(for: use.name)
        var summary = descriptor.title
        if case .object(let fields) = use.input, !fields.isEmpty {
            let detail = fields
                .sorted { $0.key < $1.key }
                .compactMap { key, value -> String? in
                    guard let text = value.stringValue ?? value.numberValue.map({ String(Int($0)) })
                    else { return nil }
                    return "\(key): \(text.prefix(80))"
                }
                .joined(separator: ", ")
            if !detail.isEmpty { summary += " — \(detail)" }
        }
        return ConfirmationRequest(
            toolName: use.name,
            summary: summary,
            bundleIdentifier: descriptor.bundleIdentifier,
            symbolName: descriptor.symbolName,
            confirmVerb: Self.verb(for: use.name)
        )
    }

    private static func verb(for toolName: String) -> String {
        switch toolName {
        case "write_file": "Write"
        case "quit_app": "Quit"
        case "run_shortcut": "Run"
        case "send_message", "compose_mail": "Send"
        default: "Confirm"
        }
    }
}
