import Foundation

/// Holds the registered tools for a session and dispatches execution by name.
public struct ToolRegistry: Sendable {
    public enum RegistryError: Error, Equatable {
        case unknownTool(String)
        case duplicateTool(String)
    }

    private struct Entry: Sendable {
        let definition: JSONValue
        let requiresConfirmation: Bool
        let execute: @Sendable (JSONValue) async throws -> ToolResult
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    public mutating func register<T: JarvisTool>(_ tool: T) throws {
        let name = T.name
        guard entries[name] == nil else { throw RegistryError.duplicateTool(name) }
        entries[name] = Entry(
            definition: T.apiDefinition,
            requiresConfirmation: T.requiresConfirmation,
            execute: { input in try await tool.execute(input) }
        )
        order.append(name)
    }

    /// Tool definitions in registration order — stable ordering matters for
    /// prompt caching (the tool block must be byte-identical across turns).
    public var apiDefinitions: [JSONValue] {
        order.compactMap { entries[$0]?.definition }
    }

    public var toolNames: [String] { order }

    public func requiresConfirmation(_ name: String) -> Bool {
        entries[name]?.requiresConfirmation ?? false
    }

    public func execute(name: String, input: JSONValue) async throws -> ToolResult {
        guard let entry = entries[name] else { throw RegistryError.unknownTool(name) }
        return try await entry.execute(input)
    }
}
