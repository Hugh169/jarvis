import Testing
import Foundation
@testable import JarvisTools

private struct EchoTool: JarvisTool {
    static let name = "echo"
    static let description = "Echoes back the provided text."
    static let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["text": ["type": "string"]],
        "required": ["text"],
    ]

    func execute(_ input: JSONValue) async throws -> ToolResult {
        ToolResult(content: input["text"]?.stringValue ?? "")
    }
}

private struct DangerousTool: JarvisTool {
    static let name = "rm_everything"
    static let description = "Pretend-destructive tool."
    static let inputSchema: JSONValue = ["type": "object", "properties": [:]]
    static let requiresConfirmation = true

    func execute(_ input: JSONValue) async throws -> ToolResult { .init(content: "boom") }
}

@Suite struct ToolRegistryTests {
    @Test func registersAndExecutes() async throws {
        var registry = ToolRegistry()
        try registry.register(EchoTool())
        let result = try await registry.execute(name: "echo", input: ["text": "hello"])
        #expect(result == ToolResult(content: "hello"))
    }

    @Test func duplicateRegistrationThrows() throws {
        var registry = ToolRegistry()
        try registry.register(EchoTool())
        #expect(throws: ToolRegistry.RegistryError.duplicateTool("echo")) {
            try registry.register(EchoTool())
        }
    }

    @Test func unknownToolThrows() async {
        let registry = ToolRegistry()
        await #expect(throws: ToolRegistry.RegistryError.unknownTool("nope")) {
            _ = try await registry.execute(name: "nope", input: .null)
        }
    }

    @Test func confirmationFlagSurfaces() throws {
        var registry = ToolRegistry()
        try registry.register(EchoTool())
        try registry.register(DangerousTool())
        #expect(!registry.requiresConfirmation("echo"))
        #expect(registry.requiresConfirmation("rm_everything"))
    }

    @Test func apiDefinitionSerializesToExpectedShape() throws {
        let data = try JSONEncoder().encode(EchoTool.apiDefinition)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded["name"]?.stringValue == "echo")
        #expect(decoded["input_schema"]?["type"]?.stringValue == "object")
    }

    @Test func definitionsKeepRegistrationOrder() throws {
        var registry = ToolRegistry()
        try registry.register(DangerousTool())
        try registry.register(EchoTool())
        #expect(registry.toolNames == ["rm_everything", "echo"])
    }
}
