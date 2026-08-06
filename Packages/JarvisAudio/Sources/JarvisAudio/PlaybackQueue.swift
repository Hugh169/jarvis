import Foundation
import AVFoundation

/// Ordered PCM playback. TTS chunks are scheduled as they arrive so audio
/// starts on chunk one while later chunks are still being generated.
///
/// `stopAndFlush()` is synchronous so the barge-in detector can cut playback
/// dead without waiting on an actor hop.
public final class PlaybackQueue: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()

    private var isPrepared = false
    private var pendingChunks = 0
    /// Fires the first time audio actually starts for a turn — the number the
    /// latency budget is measured against.
    private var onFirstAudio: (@Sendable () -> Void)?
    private var startedThisTurn = false
    private var onDrained: (@Sendable () -> Void)?

    /// ElevenLabs `pcm_24000`: 24 kHz mono 16-bit, requested to avoid an MP3
    /// decode step before scheduling.
    public init(sampleRate: Double = 24000) {
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    public func prepare() throws {
        lock.withLock {
            guard !isPrepared else { return }
            engine.attach(player)
            // Convert on the graph: the output device rarely runs at 24 kHz.
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isPrepared = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    public func beginTurn(onFirstAudio: @escaping @Sendable () -> Void, onDrained: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.onFirstAudio = onFirstAudio
            self.onDrained = onDrained
            self.startedThisTurn = false
            self.pendingChunks = 0
        }
    }

    /// Schedules one chunk of 16-bit PCM. Order of calls is playback order.
    public func enqueue(pcm data: Data) throws {
        try prepare()
        guard let buffer = Self.buffer(from: data, format: format) else { return }

        lock.withLock { pendingChunks += 1 }

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            let drained = self.lock.withLock { () -> Bool in
                self.pendingChunks -= 1
                return self.pendingChunks == 0
            }
            if drained {
                let callback = self.lock.withLock { self.onDrained }
                callback?()
            }
        }

        if !player.isPlaying {
            player.play()
        }

        let fire = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !startedThisTurn else { return nil }
            startedThisTurn = true
            return onFirstAudio
        }
        fire?()
    }

    /// Cuts playback immediately and drops anything queued.
    public func stopAndFlush() {
        player.stop()
        lock.withLock {
            pendingChunks = 0
            startedThisTurn = false
        }
    }

    public func shutdown() {
        stopAndFlush()
        if engine.isRunning { engine.stop() }
    }

    static func buffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = data.count / bytesPerFrame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frames)
        guard let destination = buffer.int16ChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(destination, base, frames * bytesPerFrame)
        }
        return buffer
    }
}
