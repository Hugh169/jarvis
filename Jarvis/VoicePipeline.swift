import Foundation
import AVFoundation
import JarvisCore
import JarvisAudio
import JarvisSpeech
import JarvisVoice
import JarvisBrain

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
    private var vad = EnergyVAD()
    private var vadClock: TimeInterval = 0
    private var endOfSpeechDetected = false

    private(set) var metrics = TurnMetrics()

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: Listening

    func beginListening() async {
        metrics = TurnMetrics()
        vad = EnergyVAD()
        vadClock = 0
        endOfSpeechDetected = false

        let transcriber = AppleTranscriber()
        self.transcriber = transcriber

        do {
            try await transcriber.start()
        } catch {
            await fail("I couldn't start listening. \(error.localizedDescription)")
            return
        }

        // Live transcript into the HUD.
        Task { [weak self] in
            for await partial in transcriber.partials {
                await MainActor.run { self?.appState.transcript = partial }
            }
        }

        do {
            try await capture.start(
                onBuffer: { [weak self] buffer in
                    // Audio thread: hand off, do nothing expensive.
                    transcriber.append(buffer)
                    self?.trackSilence(buffer)
                },
                onLevels: { [weak self] levels in
                    Task { @MainActor in self?.appState.micLevels = levels }
                }
            )
        } catch {
            await fail("I couldn't reach the microphone. \(error.localizedDescription)")
        }
    }

    /// Energy VAD on the capture thread; end-of-speech ends the utterance
    /// without waiting for the key to be released.
    nonisolated private func trackSilence(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rms = EnergyVAD.rms(of: samples)
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate

        Task { @MainActor [weak self] in
            guard let self, !self.endOfSpeechDetected else { return }
            self.vadClock += duration
            if self.vad.process(rms: rms, at: self.vadClock) == .speechEnded {
                self.endOfSpeechDetected = true
                self.metrics.endOfSpeech = .now
                await self.endListeningAndRespond()
            }
        }
    }

    /// Push-to-talk release: end the utterance now.
    func endListening() async {
        guard !endOfSpeechDetected else { return }
        endOfSpeechDetected = true
        metrics.endOfSpeech = .now
        await endListeningAndRespond()
    }

    private func endListeningAndRespond() async {
        capture.stop()
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
        trace("respond: reading keys")
        let keychain = appState.keychain
        let anthropicRead = await Self.withTimeout(seconds: 20) {
            try await keychain.value(for: .anthropicAPIKey)
        }
        guard let anthropicKey = anthropicRead ?? nil, !anthropicKey.isEmpty else {
            await fail(
                anthropicRead == nil
                    ? "The Keychain didn't respond. Approve JARVIS's access when macOS asks, then try again."
                    : "No Anthropic API key. Add one in Settings."
            )
            return
        }
        let elevenRead = await Self.withTimeout(seconds: 10) {
            try await keychain.value(for: .elevenLabsAPIKey)
        }
        let elevenKey = (elevenRead ?? nil) ?? ""
        trace("respond: keys read")
        let voiceID = appState.selectedVoiceID

        let brain = AnthropicClient(apiKey: anthropicKey, debug: { DebugLog.write($0) })
        let speaker = ElevenLabsClient(apiKey: elevenKey)

        // Open the TTS socket up front so it isn't on the critical path when
        // the first sentence lands. Bounded: a socket that never completes its
        // handshake would otherwise hang the whole turn with no error, so a
        // failure here degrades to a text-only reply.
        var session: ElevenLabsClient.Session?
        if !elevenKey.isEmpty, let voiceID {
            trace("respond: opening tts socket")
            session = try? await speaker.synthesize(voiceID: voiceID)
            if let opening = session {
                let opened = await Self.withTimeout(seconds: 4) {
                    try await opening.open()
                    return true
                }
                if opened == nil {
                    trace("tts socket timed out — continuing without voice")
                    opening.cancel()
                    session = nil
                }
            }
        }

        trace("voice=\(voiceID ?? "none") elevenKey=\(elevenKey.isEmpty ? "missing" : "present") session=\(session == nil ? "nil" : "open")")

        if let session {
            startPlayback(from: session)
        }

        appState.replyText = ""
        var chunker = SentenceChunker()
        var spoken = ""

        metrics.requestSent = .now
        let stream = await brain.stream(
            model: ModelTier.standard.modelID,
            system: SystemPrompt.blocks(),
            messages: appState.history + [.user(transcript)],
            maxTokens: ModelTier.standard.defaultMaxTokens
        )

        trace("request sent")
        do {
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .text(let delta):
                    if metrics.firstTextDelta == nil {
                        metrics.firstTextDelta = .now
                        trace("first token")
                    }
                    appState.replyText += delta
                    for sentence in chunker.append(delta) {
                        spoken += sentence
                        try? await session?.send(text: sentence)
                    }
                case .finished:
                    break
                }
            }
            if let tail = chunker.flush() {
                spoken += tail
                try? await session?.send(text: tail)
            }
            try? await session?.finish()
            trace("model stream complete, \(appState.replyText.count) chars")
        } catch is CancellationError {
            session?.cancel()
            return
        } catch {
            session?.cancel()
            await fail(error.localizedDescription)
            return
        }

        appState.appendTurn(user: transcript, assistant: appState.replyText)

        if session == nil {
            // No voice configured: the turn is complete once the text is in.
            await appState.engine.handle(.speechFinished)
        }
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
                    await self?.appState.engine.handle(.speechFinished)
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
        turnTask?.cancel()
        turnTask = nil
        transcriber?.cancel()
        transcriber = nil
        capture.stop()
        playback.stopAndFlush()
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
