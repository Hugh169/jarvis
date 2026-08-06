import AppKit

/// Resolves real macOS app icons for tool chips, so the HUD shows the actual
/// Reminders/Weather/Messages icon rather than a generic glyph.
@MainActor
enum AppIconLoader {
    private static var cache: [String: NSImage?] = [:]

    /// Nil when the app isn't installed — callers fall back to an SF Symbol.
    static func icon(forBundleIdentifier identifier: String) -> NSImage? {
        if let cached = cache[identifier] { return cached }
        let icon = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: identifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[identifier] = icon
        return icon
    }
}
