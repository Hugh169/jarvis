import Foundation
import JarvisTools

/// Minimal Codable surface of the Anthropic Messages API. Grown as phases land;
/// no `[String: Any]` anywhere.
public enum Anthropic {
    // MARK: Request

    public struct MessagesRequest: Encodable, Sendable {
        public var model: String
        public var maxTokens: Int
        public var system: [SystemBlock]?
        public var messages: [MessageParam]
        public var tools: [JSONValue]?
        public var stream: Bool

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system, messages, tools, stream
        }

        public init(
            model: String,
            maxTokens: Int,
            system: [SystemBlock]? = nil,
            messages: [MessageParam],
            tools: [JSONValue]? = nil,
            stream: Bool = true
        ) {
            self.model = model
            self.maxTokens = maxTokens
            self.system = system
            self.messages = messages
            self.tools = tools
            self.stream = stream
        }
    }

    /// System prompt block; the stable prefix carries `cache_control` so the
    /// system + tool block is a prompt-cache hit on every turn (~90% cheaper).
    public struct SystemBlock: Encodable, Sendable {
        public var type = "text"
        public var text: String
        public var cacheControl: CacheControl?

        enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }

        public init(text: String, cached: Bool = false) {
            self.text = text
            self.cacheControl = cached ? CacheControl() : nil
        }
    }

    public struct CacheControl: Encodable, Sendable {
        public var type = "ephemeral"
        public init() {}
    }

    public struct MessageParam: Encodable, Sendable {
        public enum Role: String, Encodable, Sendable {
            case user, assistant
        }

        public var role: Role
        public var content: JSONValue

        public init(role: Role, content: JSONValue) {
            self.role = role
            self.content = content
        }

        public static func user(_ text: String) -> MessageParam {
            MessageParam(role: .user, content: .string(text))
        }
    }

    // MARK: Streaming response events (decoded from SSE `data:` payloads)

    public struct StreamEvent: Decodable, Sendable {
        public var type: String
        public var delta: Delta?
        public var contentBlock: ContentBlockStart?
        public var index: Int?

        enum CodingKeys: String, CodingKey {
            case type, delta, index
            case contentBlock = "content_block"
        }
    }

    public struct Delta: Decodable, Sendable {
        public var type: String?
        public var text: String?
        public var partialJSON: String?
        public var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    public struct ContentBlockStart: Decodable, Sendable {
        public var type: String
        public var id: String?
        public var name: String?
    }

    /// A completed tool call from the model.
    public struct ToolUse: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let input: JSONValue

        public init(id: String, name: String, input: JSONValue) {
            self.id = id
            self.name = name
            self.input = input
        }

        /// The block to echo back in the assistant turn.
        public var contentBlock: JSONValue {
            .object([
                "type": .string("tool_use"),
                "id": .string(id),
                "name": .string(name),
                "input": input,
            ])
        }
    }

    /// The matching result block sent back as a user turn.
    public static func toolResultBlock(
        id: String,
        content: String,
        isError: Bool
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("tool_result"),
            "tool_use_id": .string(id),
            "content": .string(content),
        ]
        if isError { object["is_error"] = .bool(true) }
        return .object(object)
    }
}
