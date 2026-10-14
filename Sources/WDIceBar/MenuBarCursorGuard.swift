import AppKit
import CoreGraphics

/// Balance cursor hiding around a native gesture, including its completion wait.
/// Real HID movement updates the return point; synthetic session events do not.
@MainActor
final class MenuBarCursorGuard {
    /// Enabled only by the disposable integration test, not during normal use.
    static var verificationHook: ((CGFloat) -> Void)?
    private var restorePoint: CGPoint?
    private var hidden = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hardwareMovementCount: UInt32

    private static var movementCount: UInt32 {
        CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved) &+
        CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDragged) &+
        CGEventSource.counterForEventType(.hidSystemState, eventType: .rightMouseDragged)
    }

    init(hideCursor: Bool = true) {
        restorePoint = CGEvent(source: nil)?.location
        hardwareMovementCount = Self.movementCount
        hidden = hideCursor && CGDisplayHideCursor(CGMainDisplayID()) == .success
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.observe(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    private func observe(_ event: NSEvent) {
        let count = Self.movementCount
        guard count != hardwareMovementCount, let cgEvent = event.cgEvent else { return }
        hardwareMovementCount = count
        restorePoint = cgEvent.location
    }

    func finish(restorePosition: Bool = true) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if restorePosition, let restorePoint {
            CGWarpMouseCursorPosition(restorePoint)
            if let actual = CGEvent(source: nil)?.location {
                Self.verificationHook?(hypot(actual.x - restorePoint.x, actual.y - restorePoint.y))
            }
        }
        if hidden { CGDisplayShowCursor(CGMainDisplayID()) }
        hidden = false
        restorePoint = nil
    }
}
