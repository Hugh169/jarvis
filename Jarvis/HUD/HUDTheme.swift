import SwiftUI

/// The HUD commits to one dark treatment: it floats over arbitrary desktops,
/// so it can't inherit the system appearance and stay legible.
enum HUDTheme {
    static let ink = Color(white: 0.94)
    static let inkSecondary = Color(red: 0.60, green: 0.64, blue: 0.71)
    static let inkTertiary = Color(red: 0.41, green: 0.44, blue: 0.50)

    /// Identity accent — carries "working".
    static let brass = Color(red: 0.88, green: 0.66, blue: 0.29)
    /// Reserved for a hot mic and failures.
    static let alert = Color(red: 0.91, green: 0.41, blue: 0.37)
    static let ok = Color(red: 0.39, green: 0.75, blue: 0.55)

    static let hairline = Color.white.opacity(0.10)
    static let chipFill = Color.white.opacity(0.045)
    static let chipStroke = Color.white.opacity(0.07)

    static let cornerRadius: CGFloat = 20
    static let chipRadius: CGFloat = 9
    static let width: CGFloat = 480

    static let label = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let body = Font.system(size: 15)
}

/// Uppercase monospaced caption used for zone labels.
struct EyebrowLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(HUDTheme.label)
            .tracking(0.9)
            .foregroundStyle(HUDTheme.inkTertiary)
    }
}
