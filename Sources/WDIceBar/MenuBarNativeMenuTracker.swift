import CoreGraphics
import Foundation

/// Observe native windows, but never restore a temporary icon solely because a
/// window disappeared. User input must request dismissal first.
@MainActor
final class MenuBarNativeMenuTracker {
    struct DismissalState {
        private var userRequestedDismissal = false
        private var emptySamples = 0
        private var pointerIsOutside = false
        private var pointerAwaySamples = 0

        mutating func requestDismissal() {
            userRequestedDismissal = true
        }

        mutating func observePointer(isOutside: Bool) {
            pointerIsOutside = isOutside
            if !isOutside { pointerAwaySamples = 0 }
        }

        mutating func observe(isVisible: Bool) -> Bool {
            if pointerIsOutside {
                pointerAwaySamples += 1
                if pointerAwaySamples >= 8 { return true }
            }
            if isVisible {
                emptySamples = 0
                return false
            }
            // A closed/unrecognized interface alone must not hide its anchor.
            guard userRequestedDismissal else { return false }
            emptySamples += 1
            // At 100 ms per sample, allow 0.8 s for popover/submenu transitions.
            return emptySamples >= 8
        }
    }

    private struct Window {
        let id: CGWindowID
        let frame: CGRect
        let layer: Int
    }

    private let baseline: Set<CGWindowID>
    private let itemFrame: CGRect
    private var task: Task<Void, Never>?
    private var dismissal = DismissalState()
    private var interfaceFrames: [CGRect] = []
    private var lastInterfaceFrames: [CGRect] = []
    private var hasRecognizedInterface = false
    private(set) var hasVisibleInterface = false

    init(itemFrame: CGRect) {
        self.itemFrame = itemFrame
        baseline = Set(Self.windows().map(\.id))
    }

    func start(onDismiss: @escaping @MainActor () -> Void) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.interfaceFrames = Self.windows().filter { window in
                    !self.baseline.contains(window.id) && self.isPresentation(window)
                }.map(\.frame)
                self.hasVisibleInterface = !self.interfaceFrames.isEmpty
                if self.hasVisibleInterface { self.lastInterfaceFrames = self.interfaceFrames }
                self.hasRecognizedInterface = self.hasRecognizedInterface || self.hasVisibleInterface
                if self.dismissal.observe(isVisible: self.hasVisibleInterface) {
                    onDismiss()
                    return
                }
            }
        }
    }

    func requestDismissal(at point: CGPoint?) {
        // Clicking the retained real icon may reopen its menu; keep it in place.
        if let point, itemFrame.insetBy(dx: -8, dy: -8).contains(point) { return }
        dismissal.requestDismissal()
    }

    func observePointerMovement(at point: CGPoint) {
        // If a custom interface cannot be recognized, retain the icon until an
        // explicit click/Escape instead of guessing where its menu ends.
        guard hasRecognizedInterface else { return }
        dismissal.observePointer(isOutside: MenuBarDismissalPolicy.isOutsideInteraction(point,
            itemFrame: itemFrame, interfaceFrames: interfaceFrames.isEmpty ? lastInterfaceFrames : interfaceFrames))
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
