import AppKit
import Foundation
import JarvisCore
import JarvisTools

/// `--computer-check`: report the two computer-use permissions and try one real
/// capture, writing it to `~/.jarvis/`.
///
/// Exists because the capture path cannot be unit-tested — it needs a real
/// display and a TCC grant — and because this project has been bitten before by
/// a macOS permission that was never requested: the location tools failed
/// silently for a long time and looked exactly like broken code. Finding out
/// where the grants stand is the cheapest possible first step of phase 8.
@MainActor
enum ComputerCheck {
    static func run() async {
        let status = ComputerAccess.status()
        report("screen recording: \(status.screenRecording ? "granted" : "DENIED")")
        report("accessibility:    \(status.accessibility ? "granted" : "DENIED")")
        report(status.summary)

        guard status.screenRecording else {
            report("skipping capture — asking for the grant now; approve it, then relaunch")
            // macOS never grants mid-process: the prompt appears, the user
            // approves, and the *next* launch can capture.
            ScreenCapture.requestScreenRecordingAccess()
            return
        }

        do {
            let shot = try await ScreenCapture.capture()
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".jarvis", isDirectory: true)
                .appendingPathComponent("computer-check.png")
            try shot.png.write(to: url)
            report("captured \(Int(shot.size.width))x\(Int(shot.size.height)) "
                   + "(\(shot.png.count) bytes) → \(url.path)")
            report("declare these as display_width_px/display_height_px, and read every click in the same space")
        } catch {
            report("capture failed: \(error)")
        }

        await checkPointer(status: status)
    }

    /// Proves the input path end to end **without clicking or typing anything**.
    ///
    /// A synthetic click lands on whatever is under the pointer, so it is not
    /// something to fire off unattended just to see whether the plumbing works.
    /// A move activates nothing, is visible, and exercises the same chain: the
    /// accessibility grant, `CGEvent` creation, and `post`. The pointer is put
    /// back where it was.
    private static func checkPointer(status: ComputerAccess.Status) async {
        guard status.accessibility else {
            report("skipping pointer check — accessibility not granted")
            return
        }
        guard let screen = NSScreen.main else { return }
        let size = screen.frame.size
        let space = CoordinateSpace(declared: size, screen: size)

        // `NSEvent.mouseLocation` is bottom-left origin; `CGEvent` is top-left.
        // Converting rather than comparing raw is the same discipline the
        // capture path needs — the two spaces look identical until they don't.
        func pointerInCGSpace() -> CGPoint {
            let bottomLeft = NSEvent.mouseLocation
            return CGPoint(x: bottomLeft.x, y: size.height - bottomLeft.y)
        }

        let original = pointerInCGSpace()
        let target = space.toScreen(CGPoint(x: 200, y: 200))
        InputSynthesis.move(to: target)
        try? await Task.sleep(for: .milliseconds(120))
        let landed = pointerInCGSpace()

        let dx = abs(landed.x - target.x)
        let dy = abs(landed.y - target.y)
        if dx <= 2, dy <= 2 {
            report("pointer moved to (\(Int(landed.x)), \(Int(landed.y))) as asked — input path works")
        } else {
            report("pointer asked for (\(Int(target.x)), \(Int(target.y))) "
                   + "but landed at (\(Int(landed.x)), \(Int(landed.y))) — input path is off")
        }

        InputSynthesis.move(to: original)
        report("pointer restored to (\(Int(original.x)), \(Int(original.y)))")
    }

    private static func report(_ message: String) {
        DebugLog.write("computer-check: \(message)")
        print("computer-check: \(message)")
    }
}
