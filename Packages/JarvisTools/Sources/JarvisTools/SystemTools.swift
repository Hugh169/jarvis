import Foundation
import AppKit

// MARK: - Apps

public struct OpenAppTool: JarvisTool {
    public static let name = "open_app"
    public static let description = "Open or switch to an application by name."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["name": ["type": "string", "description": "Application name, e.g. Safari."]],
        "required": ["name"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let name = input["name"]?.stringValue, !name.isEmpty else {
            return .error("Which app?")
        }
        guard let url = Self.applicationURL(named: name) else {
            return .error("Couldn't find an app called \"\(name)\".")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            return .error("Couldn't open \(name): \(error.localizedDescription)")
        }
        return ToolResult(content: "Opened \(name).")
    }

    /// Resolves by bundle id first, then by scanning the usual app directories,
    /// so "safari" matches "Safari.app".
    static func applicationURL(named name: String) -> URL? {
        if name.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return url
        }
        let bare = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let directories = [
            "/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for directory in directories {
            let candidate = URL(filePath: directory).appending(path: "\(bare).app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Case-insensitive sweep as a fallback.
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            if let match = entries.first(where: {
                $0.lowercased() == "\(bare.lowercased()).app"
            }) {
                return URL(filePath: directory).appending(path: match)
            }
        }
        return nil
    }
}

public struct QuitAppTool: JarvisTool {
    public static let name = "quit_app"
    public static let description = "Quit a running application by name."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["name": ["type": "string"]],
        "required": ["name"],
    ]
    /// Quitting can lose unsaved work.
    public static let requiresConfirmation = true

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let name = input["name"]?.stringValue?.lowercased() else { return .error("Which app?") }
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.first {
                ($0.localizedName ?? "").lowercased() == name
            }
        }
        guard let app = running else { return .error("\(name) isn't running.") }
        let quit = await MainActor.run { app.terminate() }
        return quit
            ? ToolResult(content: "Quit \(app.localizedName ?? name).")
            : .error("\(app.localizedName ?? name) refused to quit.")
    }
}

public struct ListRunningAppsTool: JarvisTool {
    public static let name = "list_running_apps"
    public static let description = "List applications currently running with a visible interface."
    public static let inputSchema: JSONValue = ["type": "object", "properties": [:]]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        let names = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
                .sorted()
        }
        return ToolResult(content: names.isEmpty ? "Nothing running." : names.joined(separator: ", "))
    }
}

// MARK: - Clipboard

public struct ClipboardReadTool: JarvisTool {
    public static let name = "clipboard_read"
    public static let description = "Read the current text contents of the clipboard."
    public static let inputSchema: JSONValue = ["type": "object", "properties": [:]]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        guard let text, !text.isEmpty else { return ToolResult(content: "The clipboard is empty.") }
        return ToolResult(content: String(text.prefix(4000)))
    }
}

public struct ClipboardWriteTool: JarvisTool {
    public static let name = "clipboard_write"
    public static let description = "Replace the clipboard contents with text."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["text": ["type": "string"]],
        "required": ["text"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let text = input["text"]?.stringValue else { return .error("Nothing to copy.") }
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return ToolResult(content: "Copied.")
    }
}

// MARK: - Volume

public struct SetVolumeTool: JarvisTool {
    public static let name = "set_volume"
    public static let description = "Set the system output volume, 0 to 100."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "level": ["type": "integer", "description": "0 is muted, 100 is loudest."]
        ],
        "required": ["level"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let raw = input["level"]?.numberValue else { return .error("What level?") }
        let level = max(0, min(100, Int(raw)))
        // AppleScript is the least fragile route to the system output volume;
        // the CoreAudio equivalent is a lot of code for the same effect.
        let script = "set volume output volume \(level)"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .error("Couldn't set the volume: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            return .error("Couldn't set the volume.")
        }
        return ToolResult(content: "Volume set to \(level).")
    }
}

// MARK: - URLs and search

public struct OpenURLTool: JarvisTool {
    public static let name = "open_url"
    public static let description = "Open a web address in the default browser."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["url": ["type": "string"]],
        "required": ["url"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let raw = input["url"]?.stringValue, let url = URL(string: raw), url.scheme != nil else {
            return .error("That isn't a valid address.")
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .error("Only http and https links can be opened.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        return opened ? ToolResult(content: "Opened \(url.host() ?? raw).") : .error("Couldn't open it.")
    }
}

public struct SearchFilesTool: JarvisTool {
    public static let name = "search_files"
    public static let description = "Search for files by name using Spotlight."
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Text to match in the filename."],
            "limit": ["type": "integer", "description": "Maximum results. Default 10."],
        ],
        "required": ["query"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let query = input["query"]?.stringValue, !query.isEmpty else {
            return .error("Search for what?")
        }
        let limit = Int(input["limit"]?.numberValue ?? 10)

        // `mdfind` rather than NSMetadataQuery: no run loop needed, and it is
        // the same Spotlight index.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/mdfind")
        process.arguments = ["-name", query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .error("Couldn't search: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let paths = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .prefix(limit)
            .map(String.init)

        guard !paths.isEmpty else { return ToolResult(content: "No files matching \"\(query)\".") }
        return ToolResult(content: paths.joined(separator: "\n"))
    }
}

// MARK: - Shortcuts

public struct RunShortcutTool: JarvisTool {
    public static let name = "run_shortcut"
    public static let description = """
        Run a shortcut from the Shortcuts app by name. Anything the user has \
        automated there is available this way.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "Exact shortcut name."],
            "input": ["type": "string", "description": "Optional text input to pass in."],
        ],
        "required": ["name"],
    ]
    /// A shortcut can do anything, so it is gated.
    public static let requiresConfirmation = true

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let name = input["name"]?.stringValue, !name.isEmpty else {
            return .error("Which shortcut?")
        }
        var arguments = ["run", name]
        if let text = input["input"]?.stringValue, !text.isEmpty {
            arguments += ["--input-path", "-"]
            return try await Self.run(arguments: arguments, stdin: text, name: name)
        }
        return try await Self.run(arguments: arguments, stdin: nil, name: name)
    }

    private static func run(arguments: [String], stdin: String?, name: String) async throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/shortcuts")
        process.arguments = arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        if let stdin {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inputPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .error(message.isEmpty ? "Shortcut \"\(name)\" failed." : message)
        }
        let result = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(content: result.isEmpty ? "Ran \"\(name)\"." : String(result.prefix(4000)))
    }

    /// Names of the user's shortcuts, injected into the system prompt so the
    /// model knows what exists.
    public static func availableShortcuts() -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }
}
