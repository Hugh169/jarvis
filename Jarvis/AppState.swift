import Foundation
import Combine
import JarvisCore

/// UI-facing state, bridged from the ConversationEngine actor.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine = ConversationEngine()
    let keychain = KeychainStore()

    @Published private(set) var turnState: TurnState = .idle

    // MARK: HUD content

    /// What the user said — partial hypotheses while listening, final after.
    @Published var transcript = ""
    @Published var transcriptIsPartial = false
    /// The spoken reply, accumulated as Claude streams.
    @Published var replyText = ""
    /// Markdown from the display_detail tool.
    @Published var detailMarkdown: String?
    @Published private(set) var activities: [ToolActivity] = []
    @Published var pendingConfirmation: ConfirmationRequest?
    /// Recent input RMS for the meter.
    @Published var micLevels: [Float] = []
    /// Reported by HUDView so the panel can resize from a fixed top edge.
    @Published var hudContentHeight: CGFloat = 0

    private var activityLog = ToolActivityLog()
    private var confirmationHandler: ((Bool) -> Void)?
    /// Long-running work is owned here, not by a view. A Task created inside the
    /// menu bar's content closure dies when the menu is dismissed.
    private var turnTask: Task<Void, Never>?

    private lazy var hud = HUDController(appState: self)
    private var stateTask: Task<Void, Never>?

    private init() {
        stateTask = Task { [weak self] in
            guard let stream = await self?.engine.states() else { return }
            for await state in stream {
                self?.apply(state)
            }
        }
    }

    private func apply(_ state: TurnState) {
        turnState = state
        if state == .idle {
            hud.hide()
        } else {
            hud.show()
        }
    }

    // MARK: Tool activity

    func beginActivity(toolName: String) -> UUID {
        let descriptor = ToolPresentation.descriptor(for: toolName)
        let activity = ToolActivity(
            toolName: toolName,
            title: descriptor.title,
            bundleIdentifier: descriptor.bundleIdentifier,
            symbolName: descriptor.symbolName
        )
        activityLog.begin(activity)
        activities = activityLog.activities
        return activity.id
    }

    func finishActivity(id: UUID, status: ToolActivity.Status) {
        guard activityLog.finish(id: id, status: status) else { return }
        activities = activityLog.activities
    }

    /// Presents a confirmation in the HUD and resumes when the user decides.
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingConfirmation = request
            confirmationHandler = { approved in
                continuation.resume(returning: approved)
            }
        }
    }

    func resolveConfirmation(approved: Bool) {
        guard let handler = confirmationHandler else { return }
        confirmationHandler = nil
        pendingConfirmation = nil
        handler(approved)
    }

    private func resetTurnContent() {
        transcript = ""
        transcriptIsPartial = false
        replyText = ""
        detailMarkdown = nil
        micLevels = []
        activityLog.clear()
        activities = []
        // A cancelled turn must not leave a caller suspended forever.
        resolveConfirmation(approved: false)
    }

    // MARK: Intents (called by HotkeyManager and UI)

    func beginListening() {
        resetTurnContent()
        transcriptIsPartial = true
        Task { await engine.handle(.listenStarted) }
    }

    func endListening() {
        // Phase 2 will hand the transcript to the brain here. For now the turn
        // just ends so the HUD hides.
        Task { await engine.handle(.cancelled) }
    }

    func toggleListening() {
        Task {
            if await engine.state == .listening {
                await engine.handle(.cancelled)
            } else {
                beginListening()
            }
        }
    }

    // MARK: Demos (stand in for the pipeline until Phase 2)

    func runDemoTurn() {
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            guard let self else { return }
            await HUDDemo.runTurn(on: self)
        }
    }

    func runDemoConfirmation() {
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            guard let self else { return }
            await HUDDemo.runConfirmation(on: self)
        }
    }

    /// Panic: cancel the in-flight turn, stop audio, kill running processes.
    /// Phase 1 only has the turn to cancel.
    func panic() {
        turnTask?.cancel()
        turnTask = nil
        resetTurnContent()
        Task { await engine.handle(.cancelled) }
    }
}
