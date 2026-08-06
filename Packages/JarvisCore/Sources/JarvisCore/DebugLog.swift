import Foundation

/// Append-only debug log at `~/.jarvis/debug.log` (spec §12).
///
/// A menu-bar-only app has no console and its `NSLog` output does not reliably
/// reach the unified log, so a stalled turn is otherwise invisible. Cheap
/// enough to leave on; gated by `isEnabled` so it can be switched off.
public enum DebugLog {
    nonisolated(unsafe) public static var isEnabled = true

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis", isDirectory: true)
            .appendingPathComponent("debug.log")
    }

    public static func write(_ message: String) {
        guard isEnabled else { return }
        let line = "\(formatter.string(from: .now)) \(message)\n"

        lock.lock()
        defer { lock.unlock() }

        let url = fileURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Truncates the log — useful between debugging runs.
    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: fileURL)
    }
}
