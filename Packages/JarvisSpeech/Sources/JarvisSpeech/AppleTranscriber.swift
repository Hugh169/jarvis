import Foundation
import Speech
import AVFoundation

/// On-device transcription via the modern Speech framework (`SpeechAnalyzer` +
/// `SpeechTranscriber`). Free, no network hop, and streams volatile results for
/// live display.
public final class AppleTranscriber: SpeechTranscribing, @unchecked Sendable {
    public enum TranscriberError: Error, LocalizedError {
        case notAuthorized
        case localeUnsupported(Locale)
        case noCompatibleAudioFormat
        case notStarted

        public var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Speech recognition permission was declined."
            case .localeUnsupported(let locale):
                "On-device speech is unavailable for \(locale.identifier)."
            case .noCompatibleAudioFormat:
                "No audio format compatible with the on-device recogniser."
            case .notStarted:
                "Transcriber used before start()."
            }
        }
    }

    public let partials: AsyncStream<String>
    private let partialContinuation: AsyncStream<String>.Continuation

    private let locale: Locale
    private let lock = NSLock()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: Speech.SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    /// Accumulated finalized text. Volatile results are display-only.
    private var finalizedText = ""

    /// Australian English by default — the accent this is actually used with.
    public init(locale: Locale = Locale(identifier: "en-AU")) {
        self.locale = locale
        (self.partials, self.partialContinuation) = AsyncStream.makeStream(of: String.self)
    }

    // MARK: Authorization

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard await Self.requestAuthorization() else { throw TranscriberError.notAuthorized }

        // `??` takes an autoclosure, which can't be async — resolve in steps.
        var resolved = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if resolved == nil {
            resolved = await Speech.SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: "en-US")
            )
        }
        guard let resolved else { throw TranscriberError.localeUnsupported(locale) }

        // `progressiveTranscription` streams volatile hypotheses as you speak,
        // which is what feeds the live transcript in the HUD.
        let transcriber = Speech.SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)

        // The language model is a download on first use.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: resolved)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noCompatibleAudioFormat
        }

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        lock.withLock {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.inputContinuation = inputContinuation
            self.analyzerFormat = format
            self.finalizedText = ""
            self.converter = nil
        }

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let combined = self.lock.withLock { () -> String in
                            self.finalizedText += (self.finalizedText.isEmpty ? "" : " ") + text
                            return self.finalizedText
                        }
                        self.partialContinuation.yield(combined)
                    } else {
                        // Volatile: show finalized text plus the live tail.
                        let prefix = self.lock.withLock { self.finalizedText }
                        self.partialContinuation.yield(
                            prefix.isEmpty ? text : prefix + " " + text
                        )
                    }
                }
            } catch {
                // Stream ended or failed; finish() surfaces whatever was final.
            }
            self.partialContinuation.finish()
        }

        try await analyzer.start(inputSequence: inputStream)
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        let (continuation, format) = lock.withLock { (inputContinuation, analyzerFormat) }
        guard let continuation, let format else { return }

        guard let converted = convert(buffer, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    public func finish() async throws -> String {
        let (continuation, analyzer) = lock.withLock { (inputContinuation, self.analyzer) }
        guard let continuation, let analyzer else { throw TranscriberError.notStarted }

        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.result

        return lock.withLock { finalizedText.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public func cancel() {
        let (continuation, analyzer) = lock.withLock { (inputContinuation, self.analyzer) }
        continuation?.finish()
        resultsTask?.cancel()
        Task { await analyzer?.cancelAndFinishNow() }
        partialContinuation.finish()
    }

    // MARK: Format conversion

    /// The mic tap runs at the input device's native format; the analyser wants
    /// its own. Converting here keeps that detail out of the audio layer.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let sourceFormat = buffer.format as AVAudioFormat? else { return nil }
        if sourceFormat == format { return buffer }

        let converter: AVAudioConverter? = lock.withLock {
            if let existing = self.converter, existing.inputFormat == sourceFormat {
                return existing
            }
            let made = AVAudioConverter(from: sourceFormat, to: format)
            self.converter = made
            return made
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        // The input block is invoked synchronously, but Swift 6 still treats it
        // as concurrently-executing, so the "already supplied" flag needs a
        // reference box rather than a captured var.
        final class SuppliedFlag: @unchecked Sendable { var value = false }
        let supplied = SuppliedFlag()

        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied.value {
                status.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
