import AppKit
import ApplicationServices
import CoreGraphics

struct StatusItemSnapshot: Identifiable {
    let id: CGWindowID
    let image: NSImage
    let label: String
}

/// Reads status-item windows through the same WindowServer API Ice uses. This is intentionally
/// isolated so macOS-specific compatibility work stays out of the UI and menu-bar control code.
@MainActor
final class StatusItemSnapshotter {
    struct TemporaryItemContext {
        fileprivate let itemWindowID: CGWindowID
        fileprivate let dividerWindowID: CGWindowID
        fileprivate let ownerPID: pid_t
        fileprivate let initialOwnerWindowIDs: Set<CGWindowID>
    }

    func capture(
        excluding ownPID: pid_t,
        excludingTitles: Set<String>,
        maximumX: CGFloat?
    ) -> [StatusItemSnapshot] {
        return statusItemWindows()
            .filter { window in
                // NSStatusItem windows are hosted by Control Center on modern macOS, so their
                // owner PID is not this app. Exclude our own two items by both possible signals.
                guard window.ownerPID != ownPID, !excludingTitles.contains(window.title) else {
                    return false
                }

                guard let maximumX else { return true }
                return window.frame.maxX <= maximumX
            }
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
                    image: NSImage(cgImage: image, size: size),
                    label: window.title.isEmpty ? window.ownerName : window.title
                )
            }
    }

    /// NSStatusBarWindow's AppKit window number is not always a usable CGWindowID (it can be
    /// negative on newer macOS releases). Resolve the actual WindowServer ID from the same list
    /// used for snapshots instead.
    func statusItemWindowID(titled title: String) -> CGWindowID? {
        statusItemWindows().first { $0.title == title }?.id
    }

    /// Temporarily moves just one hidden item to the visible side of the divider, then clicks
    /// that real status item. This mirrors Ice's interaction: the app's own menu is anchored to
    /// the real menu-bar item instead of to our copied image.
    func temporarilyShowAndClick(
        windowID: CGWindowID,
        toRightOf dividerWindowID: CGWindowID,
        promptingForAccessibility: Bool
    ) async -> TemporaryItemContext? {
        guard
            accessibilityIsTrusted(prompting: promptingForAccessibility),
            let item = statusWindow(for: windowID),
            let dividerFrame = windowFrame(for: dividerWindowID)
        else {
            return nil
        }

        let initialOwnerWindowIDs = Set(onScreenWindowIDs(ownerPID: item.ownerPID))
        guard await commandDrag(
            windowID: windowID,
            from: item.frame,
            to: CGPoint(x: dividerFrame.maxX, y: dividerFrame.midY),
            targeting: dividerWindowID
        ),
              await waitForPosition(of: windowID, rightOf: dividerWindowID)
        else {
            return nil
        }

        guard click(windowID: windowID, promptingForAccessibility: false) else {
            return nil
        }

        return TemporaryItemContext(
            itemWindowID: windowID,
            dividerWindowID: dividerWindowID,
            ownerPID: item.ownerPID,
            initialOwnerWindowIDs: initialOwnerWindowIDs
        )
    }

    /// Waits for the interface opened by a status item to close. Some menu-bar apps do not
    /// expose their menu as a normal window; in that case use a short, conservative fallback.
    func waitForTemporaryInterfaceToClose(_ context: TemporaryItemContext) async {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }

        let interfaceWindowIDs = Set(onScreenWindowIDs(ownerPID: context.ownerPID))
            .subtracting(context.initialOwnerWindowIDs)
            .subtracting([context.itemWindowID])

        guard !interfaceWindowIDs.isEmpty else {
            try? await Task.sleep(for: .seconds(2))
            return
        }

        for _ in 0..<200 {
            guard !Task.isCancelled else { return }
            let currentIDs = Set(onScreenWindowIDs(ownerPID: context.ownerPID))
            if interfaceWindowIDs.isDisjoint(with: currentIDs) {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Returns a temporarily shown item to the hidden side of our divider.
    @discardableResult
    func rehideTemporaryItem(_ context: TemporaryItemContext) async -> Bool {
        guard
            let itemFrame = windowFrame(for: context.itemWindowID),
            let dividerFrame = windowFrame(for: context.dividerWindowID)
        else {
            return false
        }
        return await commandDrag(
            windowID: context.itemWindowID,
            from: itemFrame,
            to: CGPoint(x: dividerFrame.minX, y: dividerFrame.midY),
            targeting: context.dividerWindowID
        )
    }

    /// Sends the same click a user would to a real, visible status item. macOS requires
    /// Accessibility permission for synthesized input, so the first click can display the
    /// system permission prompt instead of silently doing nothing.
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

    private func commandDrag(
        windowID: CGWindowID,
        from sourceFrame: CGRect,
        to destination: CGPoint,
        targeting targetWindowID: CGWindowID
    ) async -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let originalCursorLocation = CGEvent(source: nil)?.location
        defer {
            if let originalCursorLocation {
                CGWarpMouseCursorPosition(originalCursorLocation)
            }
        }

        guard
            let item = statusWindow(for: windowID),
            let target = statusWindow(for: targetWindowID),
            let mouseDown = menuBarItemEvent(
                type: .leftMouseDown,
                location: CGPoint(x: 20_000, y: 20_000),
                targetWindowID: item.id,
                ownerPID: item.ownerPID,
                source: source,
                flags: .maskCommand
            ),
            let mouseUp = menuBarItemEvent(
                type: .leftMouseUp,
                location: destination,
                targetWindowID: target.id,
                ownerPID: item.ownerPID,
                source: source,
                flags: []
            )
        else {
            return false
        }

        // The WindowServer only honors an automated menu-bar move when the events name both the
        // source and destination status windows. This is the small, self-contained portion of
        // Ice's event routing that makes an off-screen item movable.
        for event in [mouseDown, mouseUp] {
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(35))
        }
        return true
    }

    private func menuBarItemEvent(
        type: CGEventType,
        location: CGPoint,
        targetWindowID: CGWindowID,
        ownerPID: pid_t,
        source: CGEventSource,
        flags: CGEventFlags
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else {
            return nil
        }

        event.flags = flags
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ownerPID))
        event.setIntegerValueField(.eventSourceUserData, value: Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event))))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(targetWindowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(targetWindowID))
        event.setIntegerValueField(CGEventField(rawValue: 0x33)!, value: Int64(targetWindowID))
        return event
    }

    private func waitForPosition(of windowID: CGWindowID, rightOf dividerWindowID: CGWindowID) async -> Bool {
        for _ in 0..<20 {
            guard !Task.isCancelled else { return false }
            if
                let itemFrame = windowFrame(for: windowID),
                let dividerFrame = windowFrame(for: dividerWindowID),
                itemFrame.minX >= dividerFrame.maxX - 1
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
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

    private func statusWindow(for windowID: CGWindowID) -> StatusWindow? {
        statusItemWindows().first { $0.id == windowID }
    }

    private func onScreenWindowIDs(ownerPID: pid_t) -> [CGWindowID] {
        guard let descriptions = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return descriptions.compactMap { description in
            guard description[kCGWindowOwnerPID] as? pid_t == ownerPID else { return nil }
            return description[kCGWindowNumber] as? CGWindowID
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
