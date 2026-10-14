import CoreGraphics
import Testing
@testable import WDIceBar

@MainActor
struct StatusItemScreenCaptureTests {
    @Test func cropsRetinaMenuBarUsingActualPixelDimensions() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let rect = StatusItemScreenCapture.cropRect(item: CGRect(x: 1400, y: 0, width: 38, height: 33),
            display: display, stripHeight: 33, pixelSize: CGSize(width: 3456, height: 66))
        #expect(rect == CGRect(x: 2800, y: 0, width: 76, height: 66))
    }

    @Test func supportsExternalDisplayOriginsAndRejectsOffscreenAndPopupFrames() {
        let display = CGRect(x: -1920, y: 50, width: 1920, height: 1080)
        #expect(StatusItemScreenCapture.cropRect(item: CGRect(x: -100, y: 50, width: 30, height: 24),
            display: display, stripHeight: 24, pixelSize: CGSize(width: 1920, height: 24)) == CGRect(x: 1820, y: 0, width: 30, height: 24))
        #expect(StatusItemScreenCapture.cropRect(item: CGRect(x: -2000, y: 50, width: 30, height: 24),
            display: display, stripHeight: 24, pixelSize: CGSize(width: 1920, height: 24)) == nil)
        #expect(StatusItemScreenCapture.cropRect(item: CGRect(x: -100, y: 74, width: 30, height: 100),
            display: display, stripHeight: 24, pixelSize: CGSize(width: 1920, height: 24)) == nil)
    }
}
