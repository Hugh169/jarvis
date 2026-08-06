import Foundation
import Combine
import JarvisCore
import JarvisBrain
import JarvisVoice

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
    /// Surfaced in the HUD when a turn fails.
    @Published var lastError: String?
    /// Last turn's latency breakdown, shown in Settings.
    @Published var lastLatencySummary: String?

    /// Chosen ElevenLabs voice. Persisted so it survives relaunch.
    @Published var selectedVoiceID: String? {
        didSet { UserDefaults.standard.set(selectedVoiceID, forKey: Self.voiceKey) }
    }

    /// Which model answers. Sonnet is the spec's default; Haiku is materially
    /// faster to first token, which is what the latency budget is made of.
    @Published var modelTier: ModelTier = .standard {
        didSet { UserDefaults.standard.set(modelTier.rawValue, forKey: Self.tierKey) }
    }

    /// Whether talking over JARVIS interrupts it.
    @Published var bargeInEnabled: Bool = true {
        didSet { UserDefaults.standard.set(bargeInEnabled, forKey: Self.bargeEnabledKey) }
    }

    /// 0 = only a raised voice interrupts, 1 = twitchy. Needs to be adjustable:
    /// on speakers the mic hears JARVIS itself, and the right threshold depends
    /// on the room and the volume.
    @Published var bargeInSensitivity: Float = 0.5 {
        didSet { UserDefaults.standard.set(bargeInSensitivity, forKey: Self.bargeSensitivityKey) }
    }

    private static let voiceKey = "selectedVoiceID"
    private static let tierKey = "modelTier"
    private static let bargeEnabledKey = "bargeInEnabled"
    private static let bargeSensitivityKey = "bargeInSensitivity"

    /// Rolling conversation context sent with each turn.
    private(set) var history: [Anthropic.MessageParam] = []
    /// Spec §8: keep roughly the last 20 turns.
    private let maxHistoryMessages = 40

    private var activityLog = ToolActivityLog()
    private var confirmationHandler: ((Bool) -> Void)?
    /// Long-running work is owned here, not by a view. A Task created inside the
    /// menu bar's content closure dies when the menu is dismissed.
    private var turnTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private lazy var hud = HUDController(appState: self)
    private lazy var pipeline = VoicePipeline(appState: self)
    private var stateTask: Task<Void, Never>?

    private init() {
        selectedVoiceID = UserDefaults.standard.string(forKey: Self.voiceKey)
        if let raw = UserDefaults.standard.string(forKey: Self.tierKey),
           let tier = ModelTier(rawValue: raw) {
            modelTier = tier
        }
        if UserDefaults.standard.object(forKey: Self.bargeEnabledKey) != nil {
            bargeInEnabled = UserDefaults.standard.bool(forKey: Self.bargeEnabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.bargeSensitivityKey) != nil {
            bargeInSensitivity = UserDefaults.standard.float(forKey: Self.bargeSensitivityKey)
        }
        stateTask = Task { [weak self] in
            guard let stream = await self?.engine.states() else { return }
            for await state in stream {
                self?.apply(state)
            }
        }
    }

    private func apply(_ state: TurnState) {
        turnState = state
        hideTask?.cancel()

        guard state == .idle else {
            hud.show()
            return
        }

        // Turn over: release the microphone. It is held open through thinking
        // and speaking so barge-in can hear you, but holding it while idle
        // would leave the recording indicator lit for no reason.
        pipeline.turnFinished()

        // The spec's dismissal rule: linger briefly after a turn so the last
        // reply is readable, and longer when detail is on screen. Always
        // bounded — a HUD that can get stuck on screen is worse than one that
        // leaves too early.
        let delay: Duration = detailMarkdown == nil ? .seconds(2.5) : .seconds(10)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.turnState == .idle else { return }
            self.hud.hide()
            self.detailMarkdown = nil
        }
    }

    /// Skips the lingering delay — for the panic key and explicit cancels.
    private func hideNow() {
        hideTask?.cancel()
        hideTask = nil
        hud.hide()
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

    /// Keys are cached after the first successful read: `SecItemCopyMatching`
    /// is not free and sits directly on the turn's latency path, so re-reading
    /// it every turn spends the budget for nothing. Cleared when Settings
    /// writes a new key.
    private var cachedKeys: [KeychainStore.Key: String] = [:]

    func apiKey(_ key: KeychainStore.Key) async -> String? {
        if let cached = cachedKeys[key] { return cached }
        guard let value = try? await keychain.value(for: key), !value.isEmpty else { return nil }
        cachedKeys[key] = value
        return value
    }

    /// Called after Settings saves, so the next turn picks up the change.
    func invalidateKeyCache() {
        cachedKeys.removeAll()
    }

    /// Warms the key cache so the first turn doesn't pay for it.
    func preloadKeys() {
        Task { [weak self] in
            _ = await self?.apiKey(.anthropicAPIKey)
            _ = await self?.apiKey(.elevenLabsAPIKey)
        }
    }

    /// Clears the previous turn's content when the user interrupts, keeping the
    /// HUD visible — the panel is already up and should stay up.
    func prepareForBargeInTurn() {
        transcript = ""
        transcriptIsPartial = true
        replyText = ""
        detailMarkdown = nil
        lastError = nil
        activityLog.clear()
        activities = []
        hideTask?.cancel()
    }

    /// Records a completed exchange for context on later turns.
    func appendTurn(user: String, assistant: String) {
        history.append(.user(user))
        if !assistant.isEmpty {
            history.append(Anthropic.MessageParam(role: .assistant, content: .string(assistant)))
        }
        if history.count > maxHistoryMessages {
            history.removeFirst(history.count - maxHistoryMessages)
        }
    }

    private func resetTurnContent() {
        transcript = ""
        transcriptIsPartial = false
        replyText = ""
        detailMarkdown = nil
        micLevels = []
        lastError = nil
        activityLog.clear()
        activities = []
        // A cancelled turn must not leave a caller suspended forever.
        resolveConfirmation(approved: false)
    }

    // MARK: Intents (called by HotkeyManager and UI)

    func beginListening() {
        Task {
            // Pressing the key mid-reply means "stop and listen". `.listenStarted`
            // isn't a legal transition out of speaking or thinking, so without
            // this the state machine rejects it, the reply keeps playing, and
            // JARVIS transcribes its own voice into the next prompt.
            switch await engine.state {
            case .speaking, .thinking:
                await pipeline.interruptAndListen()
            case .listening:
                break
            case .idle:
                resetTurnContent()
                transcriptIsPartial = true
                await engine.handle(.listenStarted)
                await pipeline.beginListening()
            }
        }
    }

    /// Push-to-talk release. The VAD may already have ended the utterance, in
    /// which case the pipeline ignores this.
    func endListening() {
        Task { await pipeline.endListening() }
    }

    func toggleListening() {
        Task {
            if await engine.state == .listening {
                await pipeline.endListening()
            } else {
                beginListening()
            }
        }
    }

    /// Runs a full turn from typed text — no microphone. See `--say`.
    func runTextTurn(_ text: String) {
        turnTask?.cancel()
        resetTurnContent()
        turnTask = Task { [weak self] in
            guard let self else { return }
            await self.pipeline.runTextTurn(text)
        }
    }

    /// Picks a British voice on first run so the first turn can actually speak
    /// without a visit to Settings.
    func selectDefaultVoiceIfNeeded() {
        guard selectedVoiceID == nil,
              let key = try? keychain.get(.elevenLabsAPIKey), !key.isEmpty
        else { return }

        Task { [weak self] in
            guard let self else { return }
            let british = try? await ElevenLabsClient(apiKey: key).britishVoices()
            guard let chosen = british?.first else { return }
            self.selectedVoiceID = chosen.voiceID
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
        pipeline.stop()
        resetTurnContent()
        hideNow()
        Task { await engine.handle(.cancelled) }
    }
}
