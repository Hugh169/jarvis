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
    }

    private static func report(_ message: String) {
        DebugLog.write("computer-check: \(message)")
        print("computer-check: \(message)")
    }
}
