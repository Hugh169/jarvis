import Foundation
import JarvisTools

/// Turns decoded SSE events into the client's stream events.
///
/// Split out of `AnthropicClient` because this is the fiddly part — content
/// blocks arrive in pieces, `tool_use` arguments aren't valid JSON until the
/// block closes, and server-side tools add block types that must survive the
/// round trip untouched. Inside the actor it could only be exercised over the
/// network; here a test can feed it the exact bytes the API sends.
struct StreamAssembler {
    /// Accumulates a content block while it streams. `tool_use` and
    /// `server_tool_use` arrive with an empty `input` that fills in as
    /// `input_json_delta` fragments; other blocks arrive whole and just need
    /// holding until the block closes.
    private struct PendingBlock {
        let type: String
        let raw: JSONValue
        var json = ""

        var id: String? { raw["id"]?.stringValue }
        var name: String? { raw["name"]?.stringValue }
    }

    private var pending: [Int: PendingBlock] = [:]
    private let decoder = JSONDecoder()

    init() {}

    /// Zero or more client events for one decoded SSE event.
    mutating func accept(_ event: Anthropic.StreamEvent) -> [AnthropicClient.StreamEvent] {
        switch event.type {
        case "content_block_start":
            guard let block = event.contentBlock, let index = event.index,
                  let type = block["type"]?.stringValue else { return [] }
            pending[index] = PendingBlock(type: type, raw: block)
            return []

        case "content_block_delta":
            var events: [AnthropicClient.StreamEvent] = []
            if let text = event.delta?.text, !text.isEmpty {
                events.append(.text(text))
            }
            if let fragment = event.delta?.partialJSON, let index = event.index {
                pending[index]?.json += fragment
            }
            return events

        case "content_block_stop":
            guard let index = event.index,
                  let block = pending.removeValue(forKey: index) else { return [] }
            return close(block)

        case "message_delta":
            guard let stop = event.delta?.stopReason else { return [] }
            return [.finished(stopReason: stop)]

        default:
            return []
        }
    }

    private func close(_ block: PendingBlock) -> [AnthropicClient.StreamEvent] {
        switch block.type {
        case "tool_use":
            guard let id = block.id, let name = block.name else { return [] }
            // An empty argument object streams as no deltas at all.
            let raw = block.json.isEmpty ? "{}" : block.json
            let input = decode(raw) ?? .object([:])
            return [.toolUse(Anthropic.ToolUse(id: id, name: name, input: input))]

        case "text":
            // Already delivered delta by delta.
            return []

        default:
            // A server-side block. Nothing to execute — it only has to be
            // carried back verbatim, so it is re-emitted as it arrived with any
            // streamed arguments merged back into `input`.
            return [.serverBlock(merged(block))]
        }
    }

    private func merged(_ block: PendingBlock) -> JSONValue {
        guard !block.json.isEmpty,
              case .object(var fields) = block.raw,
              let input = decode(block.json)
        else { return block.raw }
        fields["input"] = input
        return .object(fields)
    }

    private func decode(_ json: String) -> JSONValue? {
        try? decoder.decode(JSONValue.self, from: Data(json.utf8))
    }
}
