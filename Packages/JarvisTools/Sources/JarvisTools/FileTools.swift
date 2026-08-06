import Foundation

/// Directories the file tools may touch without confirmation (spec §7).
public enum FileScope {
    public static let allowedRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Documents", "Desktop", "Downloads", "Developer"].map {
            home.appending(path: $0)
        }
    }()

    /// True when `url` sits inside an allowed root. Resolves symlinks and `..`
    /// first so a path like `~/Documents/../.ssh/id_rsa` can't slip through.
    public static func isAllowed(_ url: URL) -> Bool {
        let resolved = URL(filePath: (url.path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        return allowedRoots.contains { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/")
        }
    }

    public static var describedRoots: String {
        allowedRoots.map { "~/" + $0.lastPathComponent }.joined(separator: ", ")
    }

    public static func resolve(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

public struct ReadFileTool: JarvisTool {
    public static let name = "read_file"
    public static let description = """
        Read a text file. Limited to \(FileScope.describedRoots).
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": ["path": ["type": "string", "description": "Absolute path or one starting with ~."]],
        "required": ["path"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let raw = input["path"]?.stringValue else { return .error("Which file?") }
        let url = FileScope.resolve(raw)
        guard FileScope.isAllowed(url) else {
            return .error("That's outside the folders I'm allowed to read (\(FileScope.describedRoots)).")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error("There's no file at \(url.path).")
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return .error("That doesn't look like a text file.")
        }
        // Keep the tool result small; the model doesn't need the whole thing.
        let truncated = text.count > 4000
        return ToolResult(
            content: String(text.prefix(4000)) + (truncated ? "\n…(truncated)" : "")
        )
    }
}

public struct WriteFileTool: JarvisTool {
    public static let name = "write_file"
    public static let description = """
        Write a text file. Limited to \(FileScope.describedRoots). \
        Overwrites an existing file.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "path": ["type": "string"],
            "content": ["type": "string"],
        ],
        "required": ["path", "content"],
    ]
    /// Writing can destroy existing work.
    public static let requiresConfirmation = true

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let raw = input["path"]?.stringValue,
              let content = input["content"]?.stringValue
        else { return .error("A path and some content, please.") }

        let url = FileScope.resolve(raw)
        guard FileScope.isAllowed(url) else {
            return .error("That's outside the folders I'm allowed to write to (\(FileScope.describedRoots)).")
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url)
        } catch {
            return .error("Couldn't write it: \(error.localizedDescription)")
        }
        return ToolResult(content: "Wrote \(content.count) characters to \(url.lastPathComponent).")
    }
}
