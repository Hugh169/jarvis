import AppKit
import CoreGraphics
import Foundation

/// The other half of the coordinate rule: turning a point the model named back
/// into a point on the screen.
///
/// `ScreenCapture` declares a size; the model answers in that size; this maps
/// it back. When the declared size equals the display's size in points — the
/// case on any display under the 1920×1080 cap — the mapping is the identity
/// and nothing can drift. It only does arithmetic when the capture was clamped,
/// and that is the *one* place in computer use where scaling is allowed to
/// happen. Anywhere else, it's the 2× Retina bug wearing a different hat.
public struct CoordinateSpace: Sendable, Equatable {
    /// What we told the model, via `display_width_px` / `display_height_px`.
    public let declared: CGSize
    /// The display, in points — what `CGEvent` wants.
    public let screen: CGSize

    public init(declared: CGSize, screen: CGSize) {
        self.declared = declared
        self.screen = screen
    }

    /// True when no scaling is needed. Worth asserting in tests: on this
    /// machine it must hold, and if it stops holding something fed pixels
    /// where points were expected.
    public var isIdentity: Bool { declared == screen }

    /// Maps a point the model gave us onto the screen.
    ///
    /// Both spaces are top-left origin. `CGEvent` uses global display
    /// coordinates with the origin at the top-left of the main display, and the
    /// capture is image space, which is also top-left — so there is no Y flip
    /// here. (`NSScreen.frame` *is* bottom-left origin, which is why it isn't
    /// used for this.)
    public func toScreen(_ point: CGPoint) -> CGPoint {
        guard declared.width > 0, declared.height > 0 else { return .zero }
        guard !isIdentity else { return clamped(point, to: screen) }
        let scaled = CGPoint(
            x: point.x * (screen.width / declared.width),
            y: point.y * (screen.height / declared.height)
        )
        return clamped(scaled, to: screen)
    }

    /// A model that misjudges a coordinate should click the edge, not off it.
    /// An out-of-bounds `CGEvent` is silently dropped, which looks like the
    /// click simply not working.
    private func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), max(size.width - 1, 0)),
            y: min(max(point.y, 0), max(size.height - 1, 0))
        )
    }
}

/// A key combination like `cmd+shift+4`, parsed into what `CGEvent` needs.
///
/// Pure and separately tested, because the alternative is discovering a bad
/// keymap by watching JARVIS press the wrong key on a real machine.
public struct KeyCombo: Sendable, Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags

    /// US layout. Enough for the shortcuts a computer-use turn actually reaches
    /// for; anything exotic should go through `type` as text instead.
    static let namedKeys: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
        "delete": 0x33, "backspace": 0x33, "forwarddelete": 0x75,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60,
        "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D,
        "f11": 0x67, "f12": 0x6F,
    ]

    static let letters: [String: CGKeyCode] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
        "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A,
        ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C, "`": 0x32,
    ]

    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "shift": .maskShift,
        "fn": .maskSecondaryFn,
    ]

    /// `nil` for anything unrecognised — reported as a tool error rather than
    /// guessed at, since a wrong keycode presses a real key on a real machine.
    public static func parse(_ combo: String) -> KeyCombo? {
        let parts = combo.lowercased()
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }

        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = modifiers[part] else { return nil }
            flags.insert(flag)
        }

        guard let code = namedKeys[last] ?? letters[last] else { return nil }
        return KeyCombo(keyCode: code, flags: flags)
    }
}

/// Posts synthesised mouse and keyboard events.
///
/// **Every function here moves the user's real pointer or types on their real
/// keyboard.** Nothing in this file is exercised by the test suite for that
/// reason — the tests cover `CoordinateSpace` and `KeyCombo.parse` only, which
/// is where the bugs that matter live. Posting is verified by running it, under
/// supervision, and never from a test run that might execute unattended.
///
/// Requires the accessibility grant; without it `CGEvent.post` fails silently,
/// which is the same failure shape as the location tools. `ComputerAccess`
/// reports the grant so that state is visible before anything is attempted.
public enum InputSynthesis {
    /// Posted to the session event tap, which is what reaches other
    /// applications.
    private static let tap = CGEventTapLocation.cghidEventTap

    public static func move(to point: CGPoint) {
        post(.mouseMoved, at: point, button: .left)
    }

    public static func click(at point: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
        let (down, up) = events(for: button)
        for index in 1...max(count, 1) {
            // The click count rides on the event: a double-click is not two
            // clicks, it is one event pair carrying clickCount 2. Posting two
            // singles gives you two singles.
            post(down, at: point, button: button, clickCount: index)
            post(up, at: point, button: button, clickCount: index)
        }
    }

    public static func mouseDown(at point: CGPoint, button: CGMouseButton = .left) {
        post(events(for: button).0, at: point, button: button)
    }

    public static func mouseUp(at point: CGPoint, button: CGMouseButton = .left) {
        post(events(for: button).1, at: point, button: button)
    }

    public static func drag(from start: CGPoint, to end: CGPoint) {
        post(.leftMouseDown, at: start, button: .left)
        // A single jump from start to end is ignored by most drag targets;
        // they track movement, so the drag has to actually move.
        let steps = 12
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            post(.leftMouseDragged, at: point, button: .left)
        }
        post(.leftMouseUp, at: end, button: .left)
    }

    public static func scroll(at point: CGPoint, deltaX: Int, deltaY: Int) {
        move(to: point)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        event.post(tap: tap)
    }

    /// Types text without keycodes.
    ///
    /// `keyboardSetUnicodeString` sidesteps the keymap entirely, so this is
    /// correct for accented characters, emoji, and non-US layouts — none of
    /// which a hand-written keycode table would get right.
    public static func type(_ text: String) {
        for chunk in text.chunked(into: 16) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { return }
            let utf16 = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: tap)
            up.post(tap: tap)
        }
    }

    /// `false` when the combination can't be parsed, so the caller can report
    /// it rather than press something arbitrary.
    @discardableResult
    public static func key(_ combo: String) -> Bool {
        guard let parsed = KeyCombo.parse(combo) else { return false }
        press(parsed)
        return true
    }

    @discardableResult
    public static func hold(_ combo: String, seconds: Double) async -> Bool {
        guard let parsed = KeyCombo.parse(combo) else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true)
        else { return false }
        down.flags = parsed.flags
        down.post(tap: tap)
        try? await Task.sleep(for: .seconds(seconds))
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false) {
            up.flags = parsed.flags
            up.post(tap: tap)
        }
        return true
    }

    private static func press(_ combo: KeyCombo) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: false)
        else { return }
        down.flags = combo.flags
        up.flags = combo.flags
        down.post(tap: tap)
        up.post(tap: tap)
    }

    private static func events(for button: CGMouseButton) -> (CGEventType, CGEventType) {
        switch button {
        case .right: (.rightMouseDown, .rightMouseUp)
        case .center: (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
    }

    private static func post(
        _ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickCount: Int = 1
    ) {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button
        ) else { return }
        if clickCount > 1 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: tap)
    }
}

private extension String {
    /// `keyboardSetUnicodeString` is unreliable for long strings; short chunks
    /// go through intact.
    func chunked(into size: Int) -> [String] {
        guard count > size else { return [self] }
        var result: [String] = []
        var current = startIndex
        while current < endIndex {
            let next = index(current, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[current..<next]))
            current = next
        }
        return result
    }
}
