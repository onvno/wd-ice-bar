import CoreGraphics
import Foundation

/// NSMenu's tracking loop can consume Escape and menu selections before an
/// NSEvent monitor sees them. Follow the presented window's lifetime instead.
@MainActor
final class MenuBarNativeMenuTracker {
    private struct Window {
        let id: CGWindowID
        let frame: CGRect
        let layer: Int
    }

    private let baseline: Set<CGWindowID>
    private let itemFrame: CGRect
    private var task: Task<Void, Never>?
    private var hasSeenInterface = false
    private(set) var hasVisibleInterface = false

    init(itemFrame: CGRect) {
        self.itemFrame = itemFrame
        baseline = Set(Self.windows().map(\.id))
    }

    func start(onDismiss: @escaping @MainActor () -> Void) {
        task = Task { [weak self] in
            var emptySamples = 0
            var samples = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                samples += 1
                self.hasVisibleInterface = Self.windows().contains { window in
                    !self.baseline.contains(window.id) && self.isPresentation(window)
                }
                if self.hasVisibleInterface {
                    self.hasSeenInterface = true
                    emptySamples = 0
                } else {
                    emptySamples += 1
                    // Allow two samples for transitions between menu/submenu
                    // windows. A plain action with no interface also completes.
                    if (self.hasSeenInterface && emptySamples >= 2) || (!self.hasSeenInterface && samples >= 15) {
                        onDismiss()
                        return
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func isPresentation(_ window: Window) -> Bool {
        guard window.frame.height > 0,
              abs(window.frame.minY - itemFrame.maxY) < 100 else { return false }
        // Native menus may be clamped away from their anchor at a screen edge.
        if window.layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) { return true }
        // Also support status-item popovers. Their owner may be the client app,
        // while the status item itself is hosted by Control Center.
        return window.frame.height > itemFrame.height &&
            window.layer != Int(CGWindowLevelForKey(.statusWindow)) &&
            window.frame.minX - 80 <= itemFrame.midX && window.frame.maxX + 80 >= itemFrame.midX
    }

    private static func windows() -> [Window] {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return Window(id: id, frame: CGRect(x: x, y: y, width: width, height: height), layer: layer)
        }
    }
}
