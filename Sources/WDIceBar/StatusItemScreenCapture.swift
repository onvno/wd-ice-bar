import AppKit
import ScreenCaptureKit

@MainActor
enum StatusItemScreenCapture {
    /// Capture the composited menu bar, not an off-screen status window surface.
    static func capture(windows: [StatusWindow], displayID: CGDirectDisplayID) async -> [CGWindowID: NSImage] {
        guard ScreenCapturePermission.isGranted else { return [:] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return [:] }
            let candidates = windows.filter {
                display.frame.contains($0.frame) && abs($0.frame.minY - display.frame.minY) <= 1 && $0.frame.height <= 80
            }
            guard !candidates.isEmpty else { return [:] }
            let stripHeight = candidates.map(\.frame.height).max() ?? 33
            let scale = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: display.frame.width, height: stripHeight)
            config.width = Int((display.frame.width * scale).rounded())
            config.height = Int((stripHeight * scale).rounded())
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let pixelSize = CGSize(width: image.width, height: image.height)
            var result: [CGWindowID: NSImage] = [:]
            for window in candidates {
                guard let rect = cropRect(item: window.frame, display: display.frame, stripHeight: stripHeight, pixelSize: pixelSize),
                      let cropped = image.cropping(to: rect) else { continue }
                result[window.id] = NSImage(cgImage: cropped, size: window.frame.size)
            }
            return result
        } catch {
            return [:]
        }
    }

    static func cropRect(item: CGRect, display: CGRect, stripHeight: CGFloat, pixelSize: CGSize) -> CGRect? {
        let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: stripHeight)
        guard strip.contains(item), display.width > 0, stripHeight > 0 else { return nil }
        return CGRect(x: (item.minX - display.minX) * pixelSize.width / display.width,
                      y: (item.minY - display.minY) * pixelSize.height / stripHeight,
                      width: item.width * pixelSize.width / display.width,
                      height: item.height * pixelSize.height / stripHeight).integral
    }
}
