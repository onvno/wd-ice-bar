import AppKit
import ApplicationServices
import CoreGraphics

struct StatusItemSnapshot: Identifiable {
    let id: CGWindowID
    let key: String
    let image: NSImage
    let label: String
}

/// Reads status-item windows through the same WindowServer API Ice uses. This is intentionally
/// isolated so macOS-specific compatibility work stays out of the UI and menu-bar control code.
final class StatusItemSnapshotter {
    func capture(
        excluding ownPID: pid_t,
        excludingTitles: Set<String>,
        maximumX: CGFloat?
    ) -> [StatusItemSnapshot] {
        return statusItemWindows()
            .filter { window in
                // NSStatusItem windows are hosted by Control Center on modern macOS, so their
                // owner PID is not this app. Exclude our own two items by both possible signals.
                guard window.ownerPID != ownPID,
                      !excludingTitles.contains(window.title),
                      !isSystemControlItem(window)
                else {
                    return false
                }

                guard let maximumX else { return true }
                return window.frame.maxX <= maximumX
            }
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { window in
                guard let image = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    window.id,
                    [.boundsIgnoreFraming, .bestResolution]
                ) else {
                    return nil
                }

                let size = CGSize(width: image.width / 2, height: image.height / 2)
                return StatusItemSnapshot(
                    id: window.id,
                    key: "\(window.ownerName)|\(window.title)",
                    image: NSImage(cgImage: image, size: size),
                    label: window.title.isEmpty ? window.ownerName : window.title
                )
            }
    }

    /// Reveals an original status item briefly, then sends it the same left click a user would.
    /// macOS requires Accessibility permission for synthesized input, so the first click can
    /// display the system permission prompt instead of silently doing nothing.
    @discardableResult
    func click(windowID: CGWindowID, promptingForAccessibility: Bool) -> Bool {
        guard accessibilityIsTrusted(prompting: promptingForAccessibility),
              let frame = windowFrame(for: windowID),
              let source = CGEventSource(stateID: .hidSystemState)
        else {
            return false
        }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func move(windowID: CGWindowID, nextTo targetID: CGWindowID, placingRight: Bool) -> Bool {
        guard accessibilityIsTrusted(prompting: true),
              let sourceFrame = windowFrame(for: windowID),
              let targetFrame = windowFrame(for: targetID),
              let source = CGEventSource(stateID: .hidSystemState)
        else { return false }

        let start = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        let end = CGPoint(x: placingRight ? targetFrame.maxX : targetFrame.minX, y: targetFrame.midY)
        let flags: CGEventFlags = .maskCommand
        CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left) {
            drag.flags = flags
            drag.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
        CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)?.post(tap: .cghidEventTap)
        return true
    }

    private func statusItemWindows() -> [StatusWindow] {
        let ids = privateMenuBarWindowIDs()
        guard !ids.isEmpty else { return [] }

        var rawIDs = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(kCFAllocatorDefault, &rawIDs, rawIDs.count, nil),
              let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]]
        else {
            return []
        }

        return descriptions.compactMap { description in
            guard
                let id = description[kCGWindowNumber] as? CGWindowID,
                let ownerPID = description[kCGWindowOwnerPID] as? pid_t,
                let ownerName = description[kCGWindowOwnerName] as? String,
                let layer = description[kCGWindowLayer] as? Int,
                let bounds = description[kCGWindowBounds] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                // CGSGetProcessMenuBarWindowList also contains the application's left-side
                // menus. Only status-level windows are the right-side menu bar icons.
                layer == Int(kCGStatusWindowLevel)
            else {
                return nil
            }
            let title = description[kCGWindowName] as? String ?? ""
            return StatusWindow(id: id, ownerPID: ownerPID, ownerName: ownerName, title: title, frame: frame)
        }
    }

    private func privateMenuBarWindowIDs() -> [CGWindowID] {
        var count: Int32 = 0
        guard CGSGetWindowCount(CGSMainConnectionID(), 0, &count) == .success, count > 0 else {
            return []
        }

        var ids = [CGWindowID](repeating: 0, count: Int(count))
        var actualCount: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(
            CGSMainConnectionID(),
            0,
            count,
            &ids,
            &actualCount
        ) == .success else {
            return []
        }
        return Array(ids.prefix(Int(actualCount)))
    }

    private func windowFrame(for windowID: CGWindowID) -> CGRect? {
        var rawID = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let array = CFArrayCreate(kCFAllocatorDefault, &rawID, 1, nil),
              let description = (CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]])?.first,
              let bounds = description[kCGWindowBounds] as? NSDictionary
        else {
            return nil
        }
        return CGRect(dictionaryRepresentation: bounds)
    }

    private func isSystemControlItem(_ window: StatusWindow) -> Bool {
        guard window.ownerName == "Control Center" || window.ownerName == "SystemUIServer" else {
            return window.ownerName == "Window Server"
        }
        return ["Clock", "BentoBox", "Siri", "AudioVideoModule", "FaceTime", "MusicRecognition"].contains(window.title)
    }

    private func accessibilityIsTrusted(prompting: Bool) -> Bool {
        guard prompting else { return AXIsProcessTrusted() }
        // Use the documented key string to avoid importing the mutable C global into Swift's
        // strict-concurrency model.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

private struct StatusWindow {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let frame: CGRect
}

enum ScreenCapturePermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func request() {
        CGRequestScreenCaptureAccess()
    }
}

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError
