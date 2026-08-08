import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Screen capture for computer use, and the one coordinate rule the rest of
/// phase 8 depends on.
///
/// **There is exactly one coordinate space, and it is the one we declare.**
/// A Retina Mac captures at a device pixel ratio of 2, so a 1440×900 desktop
/// produces a 2880×1800 image. Anthropic's docs offer two ways out — downscale
/// the image, or halve the coordinates the model returns — and mixing them is
/// how you get clicks landing at double the intended offset. This picks the
/// first and never does arithmetic at click time: capture, scale to the target
/// size, declare that exact size in `display_width_px`/`display_height_px`, and
/// click in that same space. If those three ever disagree, every click is wrong
/// by the ratio between them.
public enum ScreenCapture {
    public enum CaptureError: Error, Equatable {
        case noDisplay
        case screenRecordingDenied
        case captureFailed
        case encodingFailed
    }

    /// Anthropic's guidance: above this, accuracy degrades and latency rises.
    /// A Retina laptop is well under it in *points*, which is what we send —
    /// the cap applies to the declared size, not the raw pixel capture.
    static let maxWidth = 1920
    static let maxHeight = 1080

    /// The size to declare and scale to, given a display's size in points.
    ///
    /// Pure, so the clamping is testable without a screen. Aspect ratio is
    /// preserved: a stretched screenshot would move every element away from
    /// where the model computes it to be.
    static func targetSize(forDisplayOf size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(
            CGFloat(maxWidth) / size.width,
            CGFloat(maxHeight) / size.height,
            1  // never upscale — a small display stays its own size
        )
        return CGSize(
            width: (size.width * scale).rounded(.down),
            height: (size.height * scale).rounded(.down)
        )
    }

    public struct Shot: Sendable {
        /// PNG bytes, scaled to exactly `size`.
        public let png: Data
        /// The declared coordinate space. Send these as `display_width_px` and
        /// `display_height_px`, and interpret every click in them.
        public let size: CGSize
    }

    /// Whether the screen can be read at all.
    ///
    /// `CGPreflightScreenCaptureAccess` asks without prompting, so it is safe
    /// to call on a hot path. Requesting is deliberately separate — see
    /// `requestScreenRecordingAccess`.
    public static var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt, once per app per install.
    ///
    /// Returns immediately with the *current* state; macOS does not grant
    /// mid-process. The user approves in System Settings and the app has to be
    /// relaunched before capture works, which is worth saying out loud rather
    /// than leaving a turn to time out.
    @discardableResult
    public static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// `CGDisplayCreateImage` is **unavailable** on this deployment target —
    /// it's gone, not deprecated, so the compiler stops you. ScreenCaptureKit
    /// is the replacement, and it's the better fit anyway: `SCStreamConfiguration`
    /// takes the output size, so the downscale happens inside the capture
    /// pipeline instead of in a `CGContext` afterwards.
    public static func capture() async throws -> Shot {
        guard hasScreenRecordingAccess else { throw CaptureError.screenRecordingDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // ScreenCaptureKit reports a missing grant as a thrown error rather
            // than an empty result, so this is the second place the permission
            // can surface.
            throw CaptureError.screenRecordingDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        // `SCDisplay.width`/`height` are points — the space the user's own
        // clicks live in, and therefore the space worth declaring.
        let target = targetSize(forDisplayOf: CGSize(width: display.width, height: display.height))
        guard target.width > 0, target.height > 0 else { throw CaptureError.noDisplay }

        // Exclude our own windows. The HUD floats above everything, so without
        // this JARVIS photographs itself mid-turn and then reasons about a
        // panel that is its own reflection.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.width)
        configuration.height = Int(target.height)
        // Text legibility is the whole job — the model reads menu items and
        // button labels out of this image.
        configuration.scalesToFit = true
        configuration.showsCursor = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
        } catch {
            throw CaptureError.captureFailed
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed
        }
        return Shot(png: png, size: target)
    }
}

/// The two permissions computer use needs, reported together.
///
/// Kept separate from capture because they fail differently: without screen
/// recording JARVIS is blind, without accessibility it can see but cannot act.
/// Both are TCC-gated and need a human in System Settings — and, as the
/// location tools proved in this codebase, a macOS permission that is never
/// granted looks exactly like code that silently does nothing. Reporting the
/// state explicitly is what makes the difference visible.
public enum ComputerAccess {
    public struct Status: Sendable, Equatable {
        public let screenRecording: Bool
        public let accessibility: Bool

        public var ready: Bool { screenRecording && accessibility }

        /// What the user has to do, in the order they'd do it.
        public var summary: String {
            switch (screenRecording, accessibility) {
            case (true, true):
                "Screen recording and accessibility are both granted."
            case (false, true):
                "Screen recording is not granted — System Settings › Privacy & Security › Screen Recording."
            case (true, false):
                "Accessibility is not granted — System Settings › Privacy & Security › Accessibility."
            case (false, false):
                "Neither screen recording nor accessibility is granted — both live in System Settings › Privacy & Security."
            }
        }
    }

    public static func status() -> Status {
        Status(
            screenRecording: ScreenCapture.hasScreenRecordingAccess,
            // `false` for the options dictionary: report, don't prompt. The
            // prompting variant is a separate, deliberate call.
            accessibility: AXIsProcessTrusted()
        )
    }
}
