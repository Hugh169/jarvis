import CoreGraphics
import Testing
@testable import JarvisTools

/// Coordinate mapping and key parsing only.
///
/// **Nothing here posts an event.** `InputSynthesis` moves the real pointer and
/// types on the real keyboard, so a test that exercised it would take over the
/// machine of whoever ran the suite — including CI, and including an unattended
/// loop. The parts that can be wrong in an interesting way are pure, and those
/// are what's covered.
@Suite("Input synthesis")
struct InputSynthesisTests {
    // MARK: Coordinate mapping

    /// The case on this machine, and the one that must never quietly change:
    /// declared size equals the display in points, so the mapping does nothing.
    @Test("An unclamped display maps identically")
    func identityWhenUnclamped() {
        let space = CoordinateSpace(
            declared: CGSize(width: 1440, height: 900),
            screen: CGSize(width: 1440, height: 900)
        )
        #expect(space.isIdentity)
        #expect(space.toScreen(CGPoint(x: 720, y: 450)) == CGPoint(x: 720, y: 450))
        #expect(space.toScreen(CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 0))
    }

    @Test("A clamped capture scales back up to the screen")
    func scalesWhenClamped() {
        // 3840x2160 display captured at the 1920x1080 cap — exactly 2x.
        let space = CoordinateSpace(
            declared: CGSize(width: 1920, height: 1080),
            screen: CGSize(width: 3840, height: 2160)
        )
        #expect(space.isIdentity == false)
        #expect(space.toScreen(CGPoint(x: 960, y: 540)) == CGPoint(x: 1920, y: 1080))
    }

    /// An out-of-bounds CGEvent is silently dropped, which looks exactly like
    /// the click not working — so a bad coordinate hits the edge instead.
    @Test("Out-of-range points clamp to the screen rather than vanishing")
    func clampsOutOfRange() {
        let space = CoordinateSpace(
            declared: CGSize(width: 1440, height: 900),
            screen: CGSize(width: 1440, height: 900)
        )
        #expect(space.toScreen(CGPoint(x: 5000, y: 5000)) == CGPoint(x: 1439, y: 899))
        #expect(space.toScreen(CGPoint(x: -40, y: -40)) == CGPoint(x: 0, y: 0))
    }

    @Test("A degenerate space yields zero rather than dividing by zero")
    func handlesZeroSize() {
        let space = CoordinateSpace(declared: .zero, screen: CGSize(width: 1440, height: 900))
        #expect(space.toScreen(CGPoint(x: 10, y: 10)) == .zero)
    }

    // MARK: Key parsing

    @Test("A bare key parses with no modifiers")
    func parsesBareKey() {
        let combo = KeyCombo.parse("return")
        #expect(combo?.keyCode == 0x24)
        #expect(combo?.flags.isEmpty == true)
    }

    @Test("Modifiers combine")
    func parsesModifiers() {
        let combo = KeyCombo.parse("cmd+shift+4")
        #expect(combo?.keyCode == 0x15)  // "4"
        #expect(combo?.flags.contains(.maskCommand) == true)
        #expect(combo?.flags.contains(.maskShift) == true)
    }

    @Test("Modifier aliases resolve to the same flag")
    func acceptsAliases() {
        #expect(KeyCombo.parse("cmd+s") == KeyCombo.parse("command+s"))
        #expect(KeyCombo.parse("ctrl+c") == KeyCombo.parse("control+c"))
        #expect(KeyCombo.parse("alt+tab") == KeyCombo.parse("option+tab"))
    }

    @Test("Case and surrounding spaces don't matter")
    func normalisesInput() {
        #expect(KeyCombo.parse("CMD + S") == KeyCombo.parse("cmd+s"))
    }

    /// A wrong keycode presses a real key on a real machine, so anything
    /// unrecognised has to fail rather than resolve to something plausible.
    @Test("Unknown keys and modifiers fail instead of guessing")
    func rejectsUnknown() {
        #expect(KeyCombo.parse("hyper+s") == nil)
        #expect(KeyCombo.parse("cmd+nope") == nil)
        #expect(KeyCombo.parse("") == nil)
        #expect(KeyCombo.parse("cmd+") == nil)
    }

    @Test("Every named key and letter resolves")
    func tableIsComplete() {
        for name in KeyCombo.namedKeys.keys {
            #expect(KeyCombo.parse(name) != nil, "named key failed: \(name)")
        }
        for name in KeyCombo.letters.keys {
            #expect(KeyCombo.parse(name) != nil, "letter failed: \(name)")
        }
    }
}
