import Foundation
import AVFoundation
import JarvisCore
import JarvisAudio
import JarvisSpeech
import JarvisVoice
import JarvisBrain
import JarvisTools

/// Runs one voice turn end to end: mic → on-device STT → Claude (streaming) →
/// ElevenLabs → speakers.
///
/// Sentences are pushed to TTS as Claude produces them, so audio starts while
/// the model is still writing. Waiting for the full reply first would blow the
/// 1.2s budget on its own.
@MainActor
final class VoicePipeline {
    private unowned let appState: AppState
    private let capture = AudioCapture()
    private let playback = PlaybackQueue()

    private var transcriber: AppleTranscriber?
    private var turnTask: Task<Void, Never>?
    private var ttsSession: ElevenLabsClient.Session?
    /// Server-side tools never reach `ToolCoordinator`, so their HUD chips are
    /// driven straight off the content blocks instead. Keyed by the call id so
    /// the result block closes the chip its own call opened.
    private var serverActivities: [String: UUID] = [:]
    private var vad = EnergyVAD()
    private var bargeVAD = EnergyVAD(configuration: .bargeIn())
    private var vadClock: TimeInterval = 0
    private var endOfSpeechDetected = false
    private var captureRunning = false
    /// Input is ignored until this instant after an interrupt: buffers already
    /// captured still hold the tail of JARVIS's own voice, and letting the VAD
    /// see them marks speech as started and then immediately "ended", closing
    /// the new utterance before the user has said anything.
    private var ignoreInputUntil: Date?
    /// Loudest frame this utterance — logged alongside the threshold so a
    /// mis-detection can be diagnosed from real numbers rather than guessed at.
    private var peakRMS: Float = 0
    /// Ends a turn where nothing was ever said. Without it, opening the mic and
    /// staying quiet leaves it listening indefinitely — the VAD only reports an
    /// *end* of speech, which needs a start first.
    private var noSpeechTask: Task<Void, Never>?
    private var heardSpeech = false

    /// How long to wait for anything at all before giving up.
    private static let openingSilenceTimeout: Duration = .seconds(8)
    /// Shorter after a reply: the mic is open speculatively, not because the
    /// user asked for it, so it should get out of the way quickly.
    private static let followUpSilenceTimeout: Duration = .seconds(5)

    /// What the audio thread should do with each buffer. The mic stays live for
    /// the whole turn — barge-in depends on still hearing the room while JARVIS
    /// speaks — so the routing has to change underneath it.
    private let router = CaptureRouter()

    private(set) var metrics = TurnMetrics()

    init(appState: AppState) {
        self.appState = appState
    }

    /// Shared between the audio thread and the main actor, so it owns its own
    /// lock rather than relying on isolation.
    final class CaptureRouter: @unchecked Sendable {
        enum Mode { case idle, listening, awaitingReply }

        private let lock = NSLock()
        private var transcriber: AppleTranscriber?
        private var mode: Mode = .idle

        func update(mode: Mode, transcriber: AppleTranscriber?) {
            lock.withLock {
                self.mode = mode
                self.transcriber = transcriber
            }
        }

        func current() -> (Mode, AppleTranscriber?) {
            lock.withLock { (mode, transcriber) }
        }
    }

    // MARK: Listening

    func beginListening() async {
        metrics = TurnMetrics()
        // reset() rather than a fresh instance: the measured noise floor
        // describes the room and should carry between turns.
        vad.reset()
        bargeVAD = EnergyVAD(configuration: .bargeIn(sensitivity: appState.bargeInSensitivity))
        vadClock = 0
        endOfSpeechDetected = false
        peakRMS = 0

        guard await startTranscriber() else { return }
        await startCaptureIfNeeded()
        armNoSpeechTimeout(Self.openingSilenceTimeout)
    }

    /// Reopens the mic after a reply so a follow-up needs no hotkey. History
    /// already carries the previous turns, so context survives.
    func beginFollowUp() async {
        metrics = TurnMetrics()
        vad.reset()
        vadClock = 0
        endOfSpeechDetected = false
        peakRMS = 0
        // The reply just finished playing; let the speakers clear.
        ignoreInputUntil = Date.now.addingTimeInterval(0.35)

        guard await startTranscriber() else { return }
        await startCaptureIfNeeded()
        armNoSpeechTimeout(Self.followUpSilenceTimeout)
        trace("follow-up window open")
    }

    private func armNoSpeechTimeout(_ duration: Duration) {
        heardSpeech = false
        noSpeechTask?.cancel()
        noSpeechTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, !self.heardSpeech else { return }
            self.trace("nothing said — closing the turn")
            self.appState.dismiss()
        }
    }

    private func cancelNoSpeechTimeout() {
        noSpeechTask?.cancel()
        noSpeechTask = nil
    }

    /// Stops listening without ending the whole turn — used when typed input
    /// takes over from the microphone.
    func cancelListening() async {
        cancelNoSpeechTimeout()
        router.update(mode: .idle, transcriber: nil)
        transcriber?.cancel()
        transcriber = nil
        capture.stop()
        captureRunning = false
    }

    /// Push-to-talk's sibling for typing: cut the reply, drop the turn, but
    /// leave the mic shut since the user is about to type.
    func interruptForComposing() async {
        cancelNoSpeechTimeout()
        router.update(mode: .idle, transcriber: nil)
        playback.stopAndFlush()
        ttsSession?.cancel()
        ttsSession = nil
        turnTask?.cancel()
        turnTask = nil
        transcriber?.cancel()
        transcriber = nil
        capture.stop()
        captureRunning = false
        await appState.engine.handle(.bargeIn)
    }

    /// Fresh transcriber for a new utterance. The capture engine is untouched —
    /// it runs for the whole turn.
    @discardableResult
    private func startTranscriber() async -> Bool {
        let transcriber = AppleTranscriber()
        do {
            try await transcriber.start()
        } catch {
            await fail("I couldn't start listening. \(error.localizedDescription)")
            return false
        }
        self.transcriber = transcriber
        router.update(mode: .listening, transcriber: transcriber)

        // Live transcript into the HUD.
        Task { [weak self] in
            for await partial in transcriber.partials {
                await MainActor.run { self?.appState.transcript = partial }
            }
        }
        return true
    }

    private func startCaptureIfNeeded() async {
        guard !captureRunning else { return }
        do {
            try await capture.start(
                onBuffer: { [weak self] buffer in
                    // Audio thread: route and hand off, nothing expensive.
                    guard let self else { return }
                    let (mode, transcriber) = self.router.current()
                    if mode == .listening { transcriber?.append(buffer) }
                    self.trackEnergy(buffer, mode: mode)
                },
                onLevels: { [weak self] levels in
                    Task { @MainActor in self?.appState.micLevels = levels }
                }
            )
            captureRunning = true
        } catch {
            await fail("I couldn't reach the microphone. \(error.localizedDescription)")
        }
    }

    /// Energy VAD on the capture thread. While listening it detects
    /// end-of-speech; once the turn has moved on it watches for the user
    /// talking over JARVIS.
    nonisolated private func trackEnergy(_ buffer: AVAudioPCMBuffer, mode: CaptureRouter.Mode) {
        guard mode != .idle else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rms = EnergyVAD.rms(of: samples)
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.vadClock += duration

            if let until = self.ignoreInputUntil {
                guard Date.now >= until else { return }
                self.ignoreInputUntil = nil
            }

            switch mode {
            case .idle:
                break
            case .listening:
                guard !self.endOfSpeechDetected else { return }
                self.peakRMS = max(self.peakRMS, rms)
                let event = self.vad.process(rms: rms, at: self.vadClock)
                if event == .speechStarted {
                    self.heardSpeech = true
                    self.cancelNoSpeechTimeout()
                    self.trace("speech detected")
                }
                if event == .speechEnded {
                    self.endOfSpeechDetected = true
                    self.metrics.endOfSpeech = .now
                    self.trace(String(
                        format: "end of speech — peak %.4f, floor %.4f, threshold %.4f",
                        self.peakRMS,
                        self.vad.measuredNoiseFloor ?? 0,
                        self.vad.effectiveThreshold
                    ))
                    await self.endListeningAndRespond()
                }
            case .awaitingReply:
                guard self.appState.bargeInEnabled else { return }
                if self.bargeVAD.process(rms: rms, at: self.vadClock) == .speechStarted {
                    await self.handleBargeIn()
                }
            }
        }
    }

    /// The user talked over JARVIS.
    private func handleBargeIn() async {
        await interrupt(reason: "barge-in")
    }

    /// Push-to-talk pressed while JARVIS was still thinking or speaking.
    ///
    /// Deliberately ignores the barge-in setting: pressing the key is an
    /// explicit command, not a heuristic about room noise. Without this the
    /// reply keeps playing and the new transcriber hears JARVIS's own voice,
    /// which lands in the next prompt.
    func interruptAndListen() async {
        await interrupt(reason: "push-to-talk")
    }

    /// Cut audio, drop the in-flight turn, and start a fresh utterance.
    /// Everything here is synchronous or cancel-only so the audio stops
    /// promptly rather than after the next await.
    private func interrupt(reason: String) async {
        trace("interrupt: \(reason)")
        cancelNoSpeechTimeout()
        router.update(mode: .idle, transcriber: nil)

        playback.stopAndFlush()
        ttsSession?.cancel()
        ttsSession = nil
        turnTask?.cancel()
        turnTask = nil
        transcriber?.cancel()
        transcriber = nil

        await appState.engine.handle(.bargeIn)

        // Reset for the new utterance. When barge-in triggered this, the word
        // or so that tripped detection is lost — a rolling pre-roll buffer
        // would recover it. Not an issue for the key, which is pressed first.
        metrics = TurnMetrics()
        vad.reset()
        bargeVAD = EnergyVAD(configuration: .bargeIn(sensitivity: appState.bargeInSensitivity))
        vadClock = 0
        endOfSpeechDetected = false
        // Let the speaker tail clear before trusting the mic again.
        ignoreInputUntil = Date.now.addingTimeInterval(0.35)
        appState.prepareForBargeInTurn()

        // The mic may not be running if the interrupted turn came from the
        // text harness rather than a spoken one.
        await startCaptureIfNeeded()
        await startTranscriber()
    }

    /// Push-to-talk release: end the utterance now.
    func endListening() async {
        guard !endOfSpeechDetected else { return }
        endOfSpeechDetected = true
        metrics.endOfSpeech = .now
        await endListeningAndRespond()
    }

    private func endListeningAndRespond() async {
        // The mic keeps running: barge-in needs to hear the room while JARVIS
        // is thinking and speaking. Only the routing changes.
        cancelNoSpeechTimeout()
        router.update(mode: .awaitingReply, transcriber: nil)
        trace("mic still live, barge-in \(appState.bargeInEnabled ? "armed" : "off")")
        guard let transcriber else { return }

        let transcript: String
        do {
            transcript = try await transcriber.finish()
        } catch {
            await fail("I didn't catch that.")
            return
        }
        self.transcriber = nil

        metrics.transcriptReady = .now
        appState.transcript = transcript
        appState.transcriptIsPartial = false

        guard !transcript.isEmpty else {
            await appState.engine.handle(.cancelled)
            return
        }

        await appState.engine.handle(.transcriptReady)
        turnTask = Task { [weak self] in await self?.respond(to: transcript) }
    }

    /// Runs a turn from typed text, skipping mic and STT — the spec's §12 CLI
    /// harness. Iterating on the brain and voice path without speaking is far
    /// faster, and it isolates latency to the model and TTS stages.
    func runTextTurn(_ text: String) async {
        metrics = TurnMetrics()
        // No end-of-speech to measure from, so the clock starts at submission.
        metrics.endOfSpeech = .now
        metrics.transcriptReady = .now

        appState.transcript = text
        appState.transcriptIsPartial = false

        await appState.engine.handle(.listenStarted)
        await appState.engine.handle(.transcriptReady)
        await respond(to: text)
    }

    // MARK: Responding

    private func respond(to transcript: String) async {
        // Cached after the first read, so this is normally instant.
        let anthropicRead = await Self.withTimeout(seconds: 20) { [appState] in
            await appState.apiKey(.anthropicAPIKey)
        }
        guard let anthropicKey = anthropicRead ?? nil else {
            await fail(
                anthropicRead == nil
                    ? "The Keychain didn't respond. Approve JARVIS's access when macOS asks, then try again."
                    : "No Anthropic API key. Add one in Settings."
            )
            return
        }
        let elevenKey = await appState.apiKey(.elevenLabsAPIKey) ?? ""
        let voiceID = appState.selectedVoiceID

        let brain = AnthropicClient(apiKey: anthropicKey, debug: { DebugLog.write($0) })
        let speaker = ElevenLabsClient(apiKey: elevenKey)

        // Opening the TTS socket takes ~250ms. Doing it before sending the
        // model request put that time on the critical path for no reason — the
        // two are independent, so they overlap now. Bounded: a socket that
        // never finishes its handshake would otherwise hang the turn silently,
        // so a failure here degrades to a text-only reply.
        let sessionTask = Task { () -> ElevenLabsClient.Session? in
            guard !elevenKey.isEmpty, let voiceID else { return nil }
            guard let opening = try? await speaker.synthesize(voiceID: voiceID) else { return nil }
            let opened = await Self.withTimeout(seconds: 4) {
                try await opening.open()
                return true
            }
            guard opened != nil else {
                opening.cancel()
                return nil
            }
            return opening
        }

        appState.replyText = ""
        serverActivities.removeAll()
        var chunker = SentenceChunker()

        let tier = appState.modelTier
        let tools = appState.tools
        let apiTools = tools.apiTools(for: tier, webSearch: appState.webSearchEnabled)
        var messages = appState.history + [.user(transcript)]

        // Fire the model first: its first token is the long pole.
        metrics.requestSent = .now
        var stream = await brain.stream(
            model: tier.modelID,
            system: SystemPrompt.blocks(extraContext: appState.turnContext()),
            messages: messages,
            tools: apiTools,
            maxTokens: tier.defaultMaxTokens
        )

        let session = await sessionTask.value
        ttsSession = session
        trace("model=\(tier.modelID) voice=\(voiceID ?? "none") session=\(session == nil ? "nil" : "open")")
        if let session {
            startPlayback(from: session)
        }

        // Tool loop: keep going while the model asks for tools, bounded so a
        // model that never settles cannot spin forever.
        var iteration = 0
        var continuations = 0

        while true {
            var assistantBlocks: [JSONValue] = []
            var toolUses: [Anthropic.ToolUse] = []
            var pendingText = ""
            var stopReason: String?

            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let delta):
                        if metrics.firstTextDelta == nil {
                            metrics.firstTextDelta = .now
                            trace("first token")
                        }
                        // Each round's text is appended to the last round's,
                        // and the model has no idea anything preceded it — so
                        // without this the join reads "…for you.Now let me…",
                        // and the TTS says it that way too.
                        var text = delta
                        if pendingText.isEmpty, let last = appState.replyText.last,
                           !last.isWhitespace, !delta.hasPrefix(" ") {
                            text = " " + delta
                        }
                        pendingText += text
                        appState.replyText += text
                        for sentence in chunker.append(text) {
                            try? await session?.send(text: sentence)
                        }

                    case .toolUse(let use):
                        // Close the open text block first. Assistant content
                        // has to go back in the order it was produced, and
                        // text can resume after a tool block.
                        Self.flush(&pendingText, into: &assistantBlocks)
                        toolUses.append(use)
                        assistantBlocks.append(use.contentBlock)

                    case .serverBlock(let block):
                        Self.flush(&pendingText, into: &assistantBlocks)
                        assistantBlocks.append(block)
                        noteServerBlock(block)

                    case .finished(let reason):
                        stopReason = reason
                    }
                }
            } catch is CancellationError {
                session?.cancel()
                return
            } catch {
                session?.cancel()
                await fail(error.localizedDescription)
                return
            }

            Self.flush(&pendingText, into: &assistantBlocks)

            // A server-side tool ran out of its own iteration budget mid-turn.
            // Resuming means re-sending the conversation with the partial
            // assistant turn appended and *no* new user message — the server
            // picks up where it stopped. It isn't a tool round, so it gets its
            // own budget rather than eating into the tool loop's.
            if stopReason == "pause_turn" {
                guard continuations < ToolCoordinator.maxContinuations else {
                    trace("hit the pause_turn continuation cap")
                    break
                }
                continuations += 1
                trace("pause_turn — resuming (\(continuations))")
                messages.append(Anthropic.MessageParam(role: .assistant, content: .array(assistantBlocks)))
                stream = await brain.stream(
                    model: tier.modelID,
                    system: SystemPrompt.blocks(extraContext: appState.turnContext()),
                    messages: messages,
                    tools: apiTools,
                    maxTokens: tier.defaultMaxTokens
                )
                continue
            }

            guard !toolUses.isEmpty else {
                trace("stream complete, \(appState.replyText.count) chars after \(iteration) tool round(s)")
                break
            }

            trace("running \(toolUses.count) tool(s): \(toolUses.map(\.name).joined(separator: ", "))")
            messages.append(Anthropic.MessageParam(role: .assistant, content: .array(assistantBlocks)))
            let results = await tools.execute(toolUses)
            messages.append(Anthropic.MessageParam(role: .user, content: .array(results)))

            iteration += 1
            if iteration >= ToolCoordinator.maxIterations {
                trace("hit the tool-iteration cap")
                let apology = "I got stuck going round in circles there, so I have stopped."
                appState.replyText += (appState.replyText.isEmpty ? "" : " ") + apology
                try? await session?.send(text: apology)
                break
            }

            stream = await brain.stream(
                model: tier.modelID,
                system: SystemPrompt.blocks(extraContext: appState.turnContext()),
                messages: messages,
                tools: apiTools,
                maxTokens: tier.defaultMaxTokens
            )
        }

        if let tail = chunker.flush() {
            try? await session?.send(text: tail)
        }
        try? await session?.finish()

        // Draw the answer while it is being spoken. Detached from the turn so
        // the speech and the follow-up window aren't waiting on it — by the
        // time the sentence in the air has finished, the panel has filled in
        // underneath it.
        let spoken = appState.replyText
        Task { [weak appState] in
            guard let appState else { return }
            await Visualiser.illustrate(
                question: transcript, answer: spoken, apiKey: anthropicKey, into: appState
            )
        }

        appState.appendTurn(user: transcript, assistant: appState.replyText)

        if session == nil {
            // No voice configured: the turn is complete once the text is in.
            await appState.engine.handle(.speechFinished)
            await offerFollowUp()
        }
    }

    /// Closes the open text block so assistant content is carried back in the
    /// order the model produced it. Text can resume after a tool block, so this
    /// runs at every boundary rather than once at the end.
    private static func flush(_ text: inout String, into blocks: inout [JSONValue]) {
        guard !text.isEmpty else { return }
        blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        text = ""
    }

    /// Mirrors a server-side tool call into the HUD: the `server_tool_use`
    /// block opens a chip, the matching result block closes it.
    private func noteServerBlock(_ block: JSONValue) {
        guard let type = block["type"]?.stringValue else { return }

        if type == "server_tool_use" {
            guard let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue else { return }
            serverActivities[id] = appState.beginActivity(toolName: name)
            if let query = block["input"]?["query"]?.stringValue {
                trace("\(name): \(query)")
            }
            return
        }

        // Every server result block names the call it answers.
        guard let id = block["tool_use_id"]?.stringValue,
              let activity = serverActivities.removeValue(forKey: id) else { return }

        // A failed search is still HTTP 200 and still a well-formed block: the
        // difference is that `content` comes back as a single error object
        // rather than the usual array of results.
        let failure = block["content"]?["error_code"]?.stringValue
        let status: ToolActivity.Status = failure.map { .failed($0) } ?? .succeeded
        appState.finishActivity(id: activity, status: status)
        if let failure { trace("server tool failed: \(failure)") }
    }

    /// After a reply, reopen the mic briefly so the next thing said continues
    /// the same conversation without reaching for the hotkey.
    private func offerFollowUp() async {
        guard appState.followUpEnabled, !appState.isComposing else { return }
        guard appState.pendingConfirmation == nil else { return }
        guard await appState.engine.state == .idle else { return }
        await appState.beginFollowUpListening()
    }

    private func startPlayback(from session: ElevenLabsClient.Session) {
        try? playback.prepare()
        playback.beginTurn(
            onFirstAudio: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.metrics.firstAudioPlayed = .now
                    await self.appState.engine.handle(.speechStarted)
                    self.logMetrics()
                }
            },
            onDrained: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    await self.appState.engine.handle(.speechFinished)
                    await self.offerFollowUp()
                }
            }
        )

        Task { [weak self] in
            do {
                for try await chunk in session.audio {
                    guard let self else { return }
                    if self.metrics.firstAudioChunk == nil {
                        await MainActor.run { self.metrics.firstAudioChunk = .now }
                    }
                    try self.playback.enqueue(pcm: chunk)
                }
            } catch {
                await MainActor.run { self?.appState.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: Interruption

    /// Stops audio and cancels the in-flight turn. Phase 3 calls this from
    /// barge-in as well as the panic key.
    func stop() {
        cancelNoSpeechTimeout()
        router.update(mode: .idle, transcriber: nil)
        turnTask?.cancel()
        turnTask = nil
        ttsSession?.cancel()
        ttsSession = nil
        transcriber?.cancel()
        transcriber = nil
        capture.stop()
        captureRunning = false
        playback.stopAndFlush()
    }

    /// Called when a turn completes normally — releases the mic so it isn't
    /// held open (and the indicator lit) while idle.
    func turnFinished() {
        guard captureRunning else { return }
        trace("turn over, mic released")
        router.update(mode: .idle, transcriber: nil)
        ttsSession = nil
        capture.stop()
        captureRunning = false
    }

    private func logMetrics() {
        let summary = metrics.summary
        appState.lastLatencySummary = summary
        DebugLog.write(metrics.meetsBudget == false ? "OVER BUDGET — \(summary)" : summary)
    }

    private func fail(_ message: String) async {
        DebugLog.write("turn failed: \(message)")
        appState.lastError = message
        stop()
        await appState.engine.handle(.cancelled)
    }

    /// Stage tracing. A voice turn spans four subsystems and an LSUIElement app
    /// has no console, so without this a stall is invisible.
    private func trace(_ message: String) {
        DebugLog.write(message)
    }

    /// Races an operation against a deadline; nil means it timed out.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
