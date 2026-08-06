import Foundation
import AVFoundation

/// Microphone capture. Taps the input node and hands raw buffers to a sink,
/// while publishing RMS levels for the HUD meter and barge-in detection.
///
/// The tap stays installed while JARVIS speaks — Phase 3's barge-in depends on
/// still hearing the room during playback.
public final class AudioCapture: @unchecked Sendable {
    public enum CaptureError: Error, LocalizedError {
        case permissionDenied
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .permissionDenied: "Microphone permission was declined."
            case .engineFailed(let reason): "Audio engine failed: \(reason)"
            }
        }
    }

    /// Smoothed RMS, newest last, capped for the meter.
    public private(set) var levels: [Float] = []

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var levelSink: (@Sendable ([Float]) -> Void)?
    private var isRunning = false

    private let maxLevels = 48

    public init() {}

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// Starts the engine. `onBuffer` is called on the audio thread — keep it cheap.
    public func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevels: (@Sendable ([Float]) -> Void)? = nil
    ) async throws {
        guard await Self.requestPermission() else { throw CaptureError.permissionDenied }

        lock.withLock {
            bufferSink = onBuffer
            levelSink = onLevels
            levels = []
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw CaptureError.engineFailed("input device reported a zero sample rate")
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        lock.withLock { isRunning = true }
    }

    public func stop() {
        lock.withLock {
            guard isRunning else { return }
            isRunning = false
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            bufferSink = nil
            levelSink = nil
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let (sink, levelSink) = lock.withLock { (bufferSink, self.levelSink) }
        sink?(buffer)

        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rms = EnergyVAD.rms(of: samples)

        let snapshot: [Float] = lock.withLock {
            levels.append(rms)
            if levels.count > maxLevels { levels.removeFirst(levels.count - maxLevels) }
            return levels
        }
        levelSink?(snapshot)
    }
}
