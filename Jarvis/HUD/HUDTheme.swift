import SwiftUI

/// The HUD commits to one dark treatment: it floats over arbitrary desktops,
/// so it can't inherit the system appearance and stay legible.
///
/// Palette follows `design/jarvis-hud.dc.html` — a Stark-style reticle in cyan.
/// Colours there are authored in OKLCH; the sRGB values below are the exact
/// conversions, not eyeballed approximations.
enum HUDTheme {
    static let ink = Color(red: 0.929, green: 0.937, blue: 0.961)        // #EDEFF5
    static let inkSecondary = Color(red: 0.604, green: 0.639, blue: 0.710) // #9AA3B5
    static let inkTertiary = Color(red: 0.412, green: 0.439, blue: 0.498) // #69707F

    /// Identity. Carries listening, working, and the ambient chrome.
    /// oklch(78% 0.12 205)
    static let accent = Color(red: 0.232, green: 0.804, blue: 0.862)
    /// Slightly more saturated, for glows only. oklch(78% 0.14 205)
    static let accentGlow = Color(red: 0.0, green: 0.816, blue: 0.885)
    /// Readable text on top of a filled accent button.
    static let onAccent = Color(red: 0.024, green: 0.137, blue: 0.169)   // #06232b

    /// Reserved for "needs your go-ahead" and nothing else, so an approval
    /// request never looks like ordinary activity. oklch(78% 0.13 70)
    static let confirm = Color(red: 0.926, green: 0.657, blue: 0.319)

    static let ok = Color(red: 0.388, green: 0.753, blue: 0.549)         // #63C08C
    static let alert = Color(red: 0.910, green: 0.412, blue: 0.369)      // #E8695E

    /// Panel ground.
    ///
    /// The reference uses `rgba(14,17,26,0.74)` over `backdrop-filter:
    /// blur(40px)`. AppKit's `.ultraThinMaterial` blurs far less than that, so
    /// the same alpha leaves whatever is behind the panel legible through it.
    /// Denser here to keep the text readable over a busy window; the tint is
    /// the reference's.
    static let scrim = Color(red: 0.055, green: 0.067, blue: 0.102).opacity(0.90)

    static let hairline = Color.white.opacity(0.10)
    static let chipFill = Color.white.opacity(0.045)
    static let chipStroke = Color.white.opacity(0.07)

    static let cornerRadius: CGFloat = 20
    static let chipRadius: CGFloat = 9
    static let width: CGFloat = 480

    /// Room around the panel for the ambient glow to bleed into. The window has
    /// to be this much larger than the panel or the glow gets clipped.
    static let glowPadding: CGFloat = 34

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
