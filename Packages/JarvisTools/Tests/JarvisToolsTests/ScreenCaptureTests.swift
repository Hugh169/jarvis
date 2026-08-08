import CoreGraphics
import Testing
@testable import JarvisTools

/// The coordinate maths only. Capture itself needs a granted screen-recording
/// permission and a real display, so it is verified by running the app, not
/// here — see CLAUDE.md phase 8.
@Suite("Screen capture coordinates")
struct ScreenCaptureTests {
    @Test("A display under the cap is declared at its own size")
    func leavesSmallDisplaysAlone() {
        let target = ScreenCapture.targetSize(forDisplayOf: CGSize(width: 1440, height: 900))
        #expect(target == CGSize(width: 1440, height: 900))
    }

    /// The case that matters on this machine: a Retina laptop is 1440×900 in
    /// points and 2880×1800 in pixels. We declare and scale to points, so the
    /// cap never fires — if this ever returns 1920×1200 it means someone fed it
    /// pixels, and every click will be out by 2×.
    @Test("Points, not pixels — a Retina laptop needs no clamping")
    func retinaPointsAreUnderTheCap() {
        #expect(ScreenCapture.targetSize(forDisplayOf: CGSize(width: 1440, height: 900))
                == CGSize(width: 1440, height: 900))
    }

    @Test("An oversized display is clamped, preserving aspect ratio")
    func clampsLargeDisplays() {
        // 5120×2880 (16:9) → limited by width
        let target = ScreenCapture.targetSize(forDisplayOf: CGSize(width: 5120, height: 2880))
        #expect(target.width == 1920)
        #expect(target.height == 1080)
    }

    @Test("A tall display is clamped by height, not width")
    func clampsByTheBindingDimension() {
        // 1600×2560 portrait — height is the constraint
        let target = ScreenCapture.targetSize(forDisplayOf: CGSize(width: 1600, height: 2560))
        #expect(target.height == 1080)
        #expect(target.width == 675)  // 1600 * (1080/2560), floored
    }

    /// A stretched screenshot moves every element away from where the model
    /// computes it to be, so the ratio has to survive scaling.
    @Test("Aspect ratio survives clamping")
    func preservesAspectRatio() {
        let source = CGSize(width: 3840, height: 1600)  // ultrawide
        let target = ScreenCapture.targetSize(forDisplayOf: source)
        let sourceRatio = source.width / source.height
        let targetRatio = target.width / target.height
        #expect(abs(sourceRatio - targetRatio) < 0.01)
    }

    @Test("Never upscales — a small display stays its own size")
    func neverUpscales() {
        let target = ScreenCapture.targetSize(forDisplayOf: CGSize(width: 800, height: 600))
        #expect(target == CGSize(width: 800, height: 600))
    }

    @Test("A zero-sized display yields zero rather than a divide by zero")
    func handlesDegenerateSizes() {
        #expect(ScreenCapture.targetSize(forDisplayOf: .zero) == .zero)
        #expect(ScreenCapture.targetSize(forDisplayOf: CGSize(width: 0, height: 900)) == .zero)
    }

    @Test("Access status reports both permissions and what to do about them")
    func reportsAccessStatus() {
        let denied = ComputerAccess.Status(screenRecording: false, accessibility: false)
        #expect(denied.ready == false)
        #expect(denied.summary.contains("Neither"))

        let partial = ComputerAccess.Status(screenRecording: true, accessibility: false)
        #expect(partial.ready == false)
        #expect(partial.summary.contains("Accessibility"))

        let ready = ComputerAccess.Status(screenRecording: true, accessibility: true)
        #expect(ready.ready)
    }
}
