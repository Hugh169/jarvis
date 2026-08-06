import Foundation
import JarvisTools

/// Streaming client for the Anthropic Messages API.
public actor AnthropicClient {
    public enum ClientError: Error, LocalizedError {
        case missingAPIKey
        case http(status: Int, body: String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "No Anthropic API key — add one in Settings."
            case .http(let status, let body):
                "Anthropic API returned \(status): \(body)"
            case .transport(let reason):
                "Couldn't reach the Anthropic API: \(reason)"
            }
        }
    }

    /// One event from a streamed turn.
    public enum StreamEvent: Sendable, Equatable {
        /// A chunk of assistant text.
        case text(String)
        /// A completed tool call, once its arguments have finished streaming.
        case toolUse(Anthropic.ToolUse)
        /// The model finished; carries the stop reason.
        case finished(stopReason: String?)
    }

    /// Accumulates a `tool_use` block while its arguments stream in as
    /// `input_json_delta` fragments — the input is not valid JSON until the
    /// block closes.
    private struct PendingToolUse {
        let id: String
        let name: String
        var json = ""
    }

    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Optional sink for wire-level tracing (spec §12).
    private let debug: (@Sendable (String) -> Void)?

    public init(
        apiKey: String,
        session: URLSession = .shared,
        debug: (@Sendable (String) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.session = session
        self.debug = debug
    }

    /// Streams a completion. Text deltas arrive as soon as the model emits them
    /// so the TTS layer can start speaking the first sentence.
    public func stream(
        model: String,
        system: [Anthropic.SystemBlock],
        messages: [Anthropic.MessageParam],
        tools: [JSONValue]? = nil,
        maxTokens: Int
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(
                        model: model,
                        system: system,
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        model: String,
        system: [Anthropic.SystemBlock],
        messages: [Anthropic.MessageParam],
        tools: [JSONValue]?,
        maxTokens: Int,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = Anthropic.MessagesRequest(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: messages,
            tools: tools,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            debug?("HTTP \(http.statusCode): \(detail.prefix(400))")
            throw ClientError.http(status: http.statusCode, body: detail)
        }

        var parser = SSEParser()
        let decoder = JSONDecoder()
        var pendingTools: [Int: PendingToolUse] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()

            // `AsyncBytes.lines` does not just strip the newline — it drops
            // blank lines entirely, and a blank line is exactly what dispatches
            // an SSE event. Without restoring that boundary the parser
            // accumulates forever and never emits anything.
            //
            // Anthropic sends a single `data:` line per event, so the end of a
            // data line is the end of the event.
            var events = parser.feed(line + "\n")
            if line.hasPrefix("data:") {
                events += parser.feed("\n")
            }

            for event in events {
                guard let data = event.data.data(using: .utf8) else { continue }
                guard let decoded = try? decoder.decode(Anthropic.StreamEvent.self, from: data) else {
                    debug?("undecodable event: \(event.data.prefix(200))")
                    continue
                }
                debug?("event \(decoded.type)")

                switch decoded.type {
                case "content_block_start":
                    if let block = decoded.contentBlock, block.type == "tool_use",
                       let index = decoded.index, let id = block.id, let name = block.name {
                        pendingTools[index] = PendingToolUse(id: id, name: name)
                    }

                case "content_block_delta":
                    if let text = decoded.delta?.text, !text.isEmpty {
                        continuation.yield(.text(text))
                    }
                    if let fragment = decoded.delta?.partialJSON, let index = decoded.index {
                        pendingTools[index]?.json += fragment
                    }

                case "content_block_stop":
                    if let index = decoded.index, let pending = pendingTools.removeValue(forKey: index) {
                        // An empty argument object streams as no deltas at all.
                        let raw = pending.json.isEmpty ? "{}" : pending.json
                        let input = (try? decoder.decode(JSONValue.self, from: Data(raw.utf8)))
                            ?? .object([:])
                        continuation.yield(.toolUse(
                            Anthropic.ToolUse(id: pending.id, name: pending.name, input: input)
                        ))
                    }

                case "message_delta":
                    if let stop = decoded.delta?.stopReason {
                        continuation.yield(.finished(stopReason: stop))
                    }

                case "error":
                    throw ClientError.transport(event.data)

                default:
                    break
                }
            }
        }
    }
}
