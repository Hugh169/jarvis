import Foundation

/// Streaming text-to-speech over the ElevenLabs WebSocket endpoint.
///
/// WebSocket rather than REST so sentences can be fed in as Claude produces
/// them and audio comes back while the model is still writing. `pcm_24000`
/// avoids an MP3 decode before scheduling.
public actor ElevenLabsClient {
    public enum VoiceError: Error, LocalizedError {
        case missingAPIKey
        case connectionFailed(String)
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey: "No ElevenLabs API key — add one in Settings."
            case .connectionFailed(let reason): "Couldn't reach ElevenLabs: \(reason)"
            case .badResponse(let reason): "ElevenLabs returned something unexpected: \(reason)"
            }
        }
    }

    public struct Voice: Codable, Sendable, Identifiable, Equatable {
        public let voiceID: String
        public let name: String
        public let labels: [String: String]?

        public var id: String { voiceID }

        enum CodingKeys: String, CodingKey {
            case voiceID = "voice_id"
            case name, labels
        }

        public var accent: String? { labels?["accent"] }
    }

    private struct VoicesResponse: Codable { let voices: [Voice] }

    /// Flash v2.5: ~75 ms inference, built for conversational use. v3 and
    /// multilingual v2 are several hundred ms slower and it is audible.
    public static let defaultModel = "eleven_flash_v2_5"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: Voice catalogue

    /// Voices on the account, so Settings can offer a picker rather than a
    /// hardcoded id.
    public func voices() async throws -> [Voice] {
        guard !apiKey.isEmpty else { throw VoiceError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceError.badResponse(String(decoding: data, as: UTF8.self).prefix(200).description)
        }
        return try JSONDecoder().decode(VoicesResponse.self, from: data).voices
    }

    public func britishVoices() async throws -> [Voice] {
        try await voices().filter { voice in
            guard let accent = voice.accent?.lowercased() else { return false }
            return accent.contains("british") || accent.contains("english")
        }
    }

    // MARK: Streaming synthesis

    /// Opens a synthesis socket. Feed sentences with `send`, then `finish()`.
    /// Audio chunks arrive on the returned stream in playback order.
    public func synthesize(
        voiceID: String,
        model: String = defaultModel
    ) throws -> Session {
        guard !apiKey.isEmpty else { throw VoiceError.missingAPIKey }

        var components = URLComponents(
            string: "wss://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream-input"
        )!
        components.queryItems = [
            .init(name: "model_id", value: model),
            .init(name: "output_format", value: "pcm_24000"),
            // Cut the first chunk short so audio starts sooner; later chunks
            // have time to buffer while the opening plays.
            .init(name: "auto_mode", value: "true"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let task = session.webSocketTask(with: request)
        return Session(task: task)
    }

    /// One synthesis connection.
    public final class Session: @unchecked Sendable {
        private let task: URLSessionWebSocketTask
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        /// Audio chunks in playback order.
        public let audio: AsyncThrowingStream<Data, Error>
        private var didOpen = false
        private let lock = NSLock()

        init(task: URLSessionWebSocketTask) {
            self.task = task
            (self.audio, self.continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        }

        private struct InitMessage: Encodable {
            let text: String
            let voice_settings: VoiceSettings
            struct VoiceSettings: Encodable {
                let stability: Double
                let similarity_boost: Double
                let speed: Double
            }
        }

        private struct TextMessage: Encodable {
            let text: String
            let try_trigger_generation: Bool
        }

        private struct AudioMessage: Decodable {
            let audio: String?
            let isFinal: Bool?
            enum CodingKeys: String, CodingKey {
                case audio
                case isFinal = "is_final"
            }
        }

        public func open() async throws {
            lock.withLock {
                guard !didOpen else { return }
                didOpen = true
            }
            task.resume()

            // The protocol requires an opening message with a single space.
            let initMessage = InitMessage(
                text: " ",
                voice_settings: .init(stability: 0.4, similarity_boost: 0.75, speed: 1.0)
            )
            try await send(encodable: initMessage)
            receiveLoop()
        }

        /// Sends one sentence. `previousText`/`nextText` are not needed with
        /// auto_mode; the server keeps prosody continuous across sends on the
        /// same socket.
        public func send(text: String) async throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try await send(encodable: TextMessage(text: text + " ", try_trigger_generation: true))
        }

        /// Signals end of input; the socket closes once remaining audio arrives.
        public func finish() async throws {
            try await task.send(.string(#"{"text":""}"#))
        }

        public func cancel() {
            task.cancel(with: .goingAway, reason: nil)
            continuation.finish()
        }

        private func send(encodable: some Encodable) async throws {
            let data = try JSONEncoder().encode(encodable)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        }

        private func receiveLoop() {
            task.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.continuation.finish(throwing: error)
                case .success(let message):
                    var isFinal = false
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let decoded = try? JSONDecoder().decode(AudioMessage.self, from: data) {
                            if let base64 = decoded.audio, let audio = Data(base64Encoded: base64), !audio.isEmpty {
                                self.continuation.yield(audio)
                            }
                            isFinal = decoded.isFinal ?? false
                        }
                    case .data(let data):
                        self.continuation.yield(data)
                    @unknown default:
                        break
                    }
                    if isFinal {
                        self.continuation.finish()
                    } else {
                        self.receiveLoop()
                    }
                }
            }
        }
    }
}
