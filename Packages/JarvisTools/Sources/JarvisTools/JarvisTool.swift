import Foundation

/// Result returned to Claude after a tool executes.
public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true)
    }
}

/// Every tool conforms to this protocol and registers itself with `ToolRegistry`
/// — adding a tool touches exactly one new file.
public protocol JarvisTool: Sendable {
    static var name: String { get }
    static var description: String { get }
    /// JSON Schema for the tool's input, as a JSONValue object.
    static var inputSchema: JSONValue { get }
    /// Tools that are destructive or outward-facing must be confirmed in the HUD
    /// before executing (see safety rails, §7 of the build plan).
    static var requiresConfirmation: Bool { get }

    func execute(_ input: JSONValue) async throws -> ToolResult
}

extension JarvisTool {
    public static var requiresConfirmation: Bool { false }

    /// The Anthropic Messages API tool definition for this tool.
    public static var apiDefinition: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema,
        ])
    }
}
