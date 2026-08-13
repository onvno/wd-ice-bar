import AppKit
import ApplicationServices
import CoreGraphics

struct StatusItemSnapshot: Identifiable {
    let id: CGWindowID
    /// Best-effort identity for the current menu-bar session. `windowID` is the authoritative
    /// key while the item exists; this value helps preserve an editor selection after a refresh.
    let key: String
    let image: NSImage
    let label: String
    let usesFallbackImage: Bool
    let isOffscreen: Bool
}

/// Reads status-item windows through the same WindowServer API Ice uses. This is intentionally
/// isolated so macOS-specific compatibility work stays out of the UI and menu-bar control code.
@MainActor
final class StatusItemSnapshotter {
    enum MoveResult: Equatable {
        case moved
        case accessibilityDenied
        case sourceOrTargetMissing
        case eventRouting(MenuBarEventRouter.Result)
        case positionNotConfirmed

        var description: String {
            switch self {
            case .moved: "已移动"
            case .accessibilityDenied: "辅助功能权限不可用"
            case .sourceOrTargetMissing: "移动期间找不到源图标或分隔标记"
            case .eventRouting(let result): result.description
            case .positionNotConfirmed: "事件已送达，但 1.5 秒内未确认到新的相邻位置"
            }
        }
    }

    private let eventRouter = MenuBarEventRouter()
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

                guard isUserMenuBarItem(window) else { return false }

                guard let maximumX else { return true }
                return window.frame.maxX <= maximumX
            }
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap(snapshot(for:))
    }

    /// The private menu-bar window list can include transparent container windows and solid
    /// backing views alongside actual status-item images. Rendering those entries created a
    /// long row of empty gray placeholders. Keep only captures with visible, non-flat content.
    private func hasMeaningfulIconPixels(_ image: CGImage) -> Bool {
        let width = min(image.width, 96)
        let height = min(image.height, 48)
        guard width > 0, height > 0 else { return false }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            // If macOS cannot normalize a valid capture, keep it rather than hide a real item.
            return true
        }

        context.interpolationQuality = .none
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var visibleCount = 0
        var minimumLuminance = UInt8.max
        var maximumLuminance = UInt8.min
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            guard alpha > 12 else { continue }
            visibleCount += 1
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let luminanceValue = (77 * red + 150 * green + 29 * blue) / 256
            let luminance = UInt8(luminanceValue)
            minimumLuminance = min(minimumLuminance, luminance)
            maximumLuminance = max(maximumLuminance, luminance)
        }

        let coverage = Double(visibleCount) / Double(width * height)
        guard coverage >= 0.015 else { return false }
        // A fully opaque, near-uniform rectangle is a host/background view, not an icon. Do
        // not discard ordinary sparse icons, including black template icons with alpha.
        return !(coverage > 0.92 && maximumLuminance - minimumLuminance < 12)
    }

    /// Captures every third-party candidate, including items currently outside the visible menu
    /// bar. This is used only by the experimental layout editor.
    func captureAllCandidates(excluding ownPID: pid_t, excludingTitles: Set<String>) -> [StatusItemSnapshot] {
        capture(excluding: ownPID, excludingTitles: excludingTitles, maximumX: nil)
    }

    /// Returns status items WindowServer knows about but macOS has already laid out beyond the
    /// display's horizontal bounds. These do not belong to the normal visible group, yet they
    /// can still be shown in wd-ice-bar and later moved back through the layout editor.
    func captureOffscreenCandidates(excluding ownPID: pid_t, excludingTitles: Set<String>) -> [StatusItemSnapshot] {
        statusItemWindows()
            .filter { window in
                window.ownerPID != ownPID
                    && !excludingTitles.contains(window.title)
                    && isUserMenuBarItem(window)
                    && isHorizontallyOffscreen(window.frame)
            }
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap(snapshot(for:))
    }

    private func snapshot(for window: StatusWindow) -> StatusItemSnapshot? {
        let label = window.title.isEmpty ? window.ownerName : window.title
        if let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.id,
            [.boundsIgnoreFraming, .bestResolution]
        ), hasMeaningfulIconPixels(image) {
            let size = CGSize(width: image.width / 2, height: image.height / 2)
            return StatusItemSnapshot(
                id: window.id,
                key: "\(window.ownerPID)|\(window.ownerName)|\(window.title)",
                image: NSImage(cgImage: image, size: size),
                label: label,
                usesFallbackImage: false,
                isOffscreen: isHorizontallyOffscreen(window.frame)
            )
        }

        // Some status-item hosts keep their window and event target alive after their backing
        // image is no longer capturable. Preserve that item with a title initial instead of
        // creating an empty gap in the shelf. Restrict the fallback to icon-sized windows with
        // a usable identity so transparent container views remain excluded.
        guard isPlausibleFallbackStatusItem(window), let image = fallbackImage(for: label) else {
            return nil
        }
        return StatusItemSnapshot(
            id: window.id,
            key: "\(window.ownerPID)|\(window.ownerName)|\(window.title)",
            image: image,
            label: "\(label)（未捕捉到图标）",
            usesFallbackImage: true,
            isOffscreen: isHorizontallyOffscreen(window.frame)
        )
    }

    private func isPlausibleFallbackStatusItem(_ window: StatusWindow) -> Bool {
        guard !window.title.isEmpty || !window.ownerName.isEmpty else { return false }
        return window.frame.width >= 8
            && window.frame.width <= 96
            && window.frame.height >= 12
            && window.frame.height <= 48
    }

    private func fallbackImage(for label: String) -> NSImage? {
        let character = label.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "?"
        let image = NSImage(size: CGSize(width: 24, height: 24))
        image.lockFocus()
        defer { image.unlockFocus() }

        let seed = label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        let hue = CGFloat(seed % 360) / 360
        NSColor(calibratedHue: hue, saturation: 0.48, brightness: 0.80, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 22, height: 22), xRadius: 6, yRadius: 6).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        String(character).draw(in: NSRect(x: 1, y: 4, width: 22, height: 16), withAttributes: attributes)
        return image
    }

    private func isHorizontallyOffscreen(_ frame: CGRect) -> Bool {
        let screenRanges = NSScreen.screens.map { $0.frame.minX...$0.frame.maxX }
        guard !screenRanges.isEmpty else { return false }
        return !screenRanges.contains { range in
            frame.maxX >= range.lowerBound && frame.minX <= range.upperBound
        }
    }

    /// Moves a real status item immediately beside another real item. It is deliberately
    /// transactional: reports the precise failed stage unless WindowServer confirms adjacency.
    @discardableResult
    func move(windowID: CGWindowID, beside targetID: CGWindowID, onRight: Bool) async -> MoveResult {
        guard accessibilityIsTrusted(prompting: true) else { return .accessibilityDenied }

        var lastRoutingFailure: MenuBarEventRouter.Result?
        for _ in 0..<3 {
            guard
                let item = statusWindow(for: windowID),
                let target = statusWindow(for: targetID),
                let source = CGEventSource(stateID: .hidSystemState),
                let suppressionSource = CGEventSource(stateID: .combinedSessionState)
            else {
                return .sourceOrTargetMissing
            }

            // The actual events use the HID source, but macOS applies drag suppression to the
            // combined session source. Configuring the latter is required for a status item to
            // transition into its real ⌘-drag state (the same separation Ice uses).
            suppressionSource.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: .eventSuppressionStateRemoteMouseDrag)
            suppressionSource.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: .eventSuppressionStateSuppressionInterval)
            suppressionSource.localEventsSuppressionInterval = 0

            let destination = CGPoint(
                x: onRight ? target.frame.maxX : target.frame.minX,
                y: target.frame.midY
            )
            let routingResult = await postCommandDrag(item: item, target: target, destination: destination, source: source)
            guard routingResult == .delivered else {
                lastRoutingFailure = routingResult
                try? await Task.sleep(for: .milliseconds(80))
                continue
            }

            if await waitForAdjacency(of: windowID, beside: targetID, onRight: onRight) {
                return .moved
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return lastRoutingFailure.map(MoveResult.eventRouting) ?? .positionNotConfirmed
    }

    /// Finds the actual WindowServer ID of one of wd-ice-bar's own control items. AppKit's
    /// `windowNumber` can be negative and must not be converted directly to `CGWindowID`.
    func statusItemWindowID(titled title: String) -> CGWindowID? {
        statusItemWindows().first { $0.title == title }?.id
    }

    func isWindow(_ windowID: CGWindowID, toRightOf dividerID: CGWindowID) -> Bool? {
        guard let itemFrame = windowFrame(for: windowID), let dividerFrame = windowFrame(for: dividerID) else {
            return nil
        }
        return itemFrame.minX >= dividerFrame.maxX - 1
    }

    func isWindowHorizontallyOffscreen(_ windowID: CGWindowID) -> Bool {
        guard let frame = windowFrame(for: windowID) else { return true }
        return isHorizontallyOffscreen(frame)
    }

    /// Reveals an original status item briefly, then sends it the same mouse click a user would.
    /// macOS requires Accessibility permission for synthesized input, so the first click can
    /// display the system permission prompt instead of silently doing nothing.
    @discardableResult
    func click(windowID: CGWindowID, mouseButton: CGMouseButton, promptingForAccessibility: Bool) async -> Bool {
        guard accessibilityIsTrusted(prompting: promptingForAccessibility),
              let frame = windowFrame(for: windowID),
              let source = CGEventSource(stateID: .hidSystemState)
        else {
            return false
        }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        if mouseButton == .right,
           let item = statusWindow(for: windowID),
           let mouseDown = menuBarEvent(
               type: .rightMouseDown,
               location: point,
               targetWindowID: item.id,
               ownerPID: item.ownerPID,
               source: source,
               flags: []
           ),
           let mouseUp = menuBarEvent(
               type: .rightMouseUp,
               location: point,
               targetWindowID: item.id,
               ownerPID: item.ownerPID,
               source: source,
               flags: []
           )
        {
            // Status-item context menus are stricter than primary clicks: route the event with
            // the actual target WindowID and owner PID, matching the proven drag route.
            guard await eventRouter.route(mouseDown, to: item.ownerPID) == .delivered else { return false }
            return await eventRouter.route(mouseUp, to: item.ownerPID) == .delivered
        }

        let mouseDownType: CGEventType = mouseButton == .right ? .rightMouseDown : .leftMouseDown
        let mouseUpType: CGEventType = mouseButton == .right ? .rightMouseUp : .leftMouseUp
        CGEvent(
            mouseEventSource: source,
            mouseType: mouseDownType,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: source,
            mouseType: mouseUpType,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        )?.post(tap: .cghidEventTap)
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

    private func statusWindow(for windowID: CGWindowID) -> StatusWindow? {
        statusItemWindows().first { $0.id == windowID }
    }

    private func postCommandDrag(
        item: StatusWindow,
        target: StatusWindow,
        destination: CGPoint,
        source: CGEventSource
    ) async -> MenuBarEventRouter.Result {
        guard
            let mouseDown = menuBarEvent(
                type: .leftMouseDown,
                location: CGPoint(x: 20_000, y: 20_000),
                targetWindowID: item.id,
                ownerPID: item.ownerPID,
                source: source,
                flags: .maskCommand
            ),
            let mouseUp = menuBarEvent(
                type: .leftMouseUp,
                location: destination,
                targetWindowID: target.id,
                ownerPID: item.ownerPID,
                source: source,
                flags: []
            )
        else {
            return .targetTapUnavailable
        }

        // Route through the source process and session event stream before delivering to the
        // source process. A direct session post is ignored by current macOS status-bar hosts.
        let downResult = await eventRouter.route(mouseDown, to: item.ownerPID)
        guard downResult == .delivered else { return downResult }

        // A menu-bar status item first changes frame when macOS enters the native drag state.
        // Sending mouse-up immediately afterwards (our old behavior) is commonly ignored. Wait
        // for that transition before completing the drag, as Ice does.
        guard await waitForFrameChange(of: item.id, initialFrame: item.frame, timeout: .milliseconds(80)) else {
            if let cancelEvent = menuBarEvent(
                type: .leftMouseUp,
                location: CGPoint(x: item.frame.midX, y: item.frame.midY),
                targetWindowID: item.id,
                ownerPID: item.ownerPID,
                source: source,
                flags: []
            ) {
                _ = await eventRouter.route(cancelEvent, to: item.ownerPID)
            }
            return .dragDidNotStart
        }
        return await eventRouter.route(mouseUp, to: item.ownerPID)
    }

    private func menuBarEvent(
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

    private func waitForAdjacency(of windowID: CGWindowID, beside targetID: CGWindowID, onRight: Bool) async -> Bool {
        for _ in 0..<60 {
            guard !Task.isCancelled else { return false }
            if
                let itemFrame = windowFrame(for: windowID),
                let targetFrame = windowFrame(for: targetID)
            {
                let isOnCorrectSide = onRight
                    ? itemFrame.minX >= targetFrame.maxX - 2
                    : itemFrame.maxX <= targetFrame.minX + 2
                if isOnCorrectSide, areAdjacentInMenuBar(windowID, targetID, onRight: onRight) {
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func waitForFrameChange(of windowID: CGWindowID, initialFrame: CGRect, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return false }
            if let frame = windowFrame(for: windowID), frame != initialFrame {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func areAdjacentInMenuBar(_ windowID: CGWindowID, _ targetID: CGWindowID, onRight: Bool) -> Bool {
        let ids = statusItemWindows()
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.id)
        guard let itemIndex = ids.firstIndex(of: windowID), let targetIndex = ids.firstIndex(of: targetID) else {
            return false
        }
        return onRight ? itemIndex == targetIndex + 1 : targetIndex == itemIndex + 1
    }

    /// System-owned controls are neither reliably movable nor part of wd-ice-bar's scope.
    /// Filtering them before the editor is important: otherwise the date and Control Center can
    /// accidentally be treated as ordinary app icons.
    private func isUserMenuBarItem(_ window: StatusWindow) -> Bool {
        let systemOwners: Set<String> = ["Control Center", "SystemUIServer", "Window Server"]
        guard !systemOwners.contains(window.ownerName) else { return false }
        let reservedTitles: Set<String> = ["Clock", "BentoBox", "Siri", "AudioVideoModule", "FaceTime", "MusicRecognition"]
        // System modules expose implementation-specific suffixes such as "BentoBox-0". They
        // can be captured as status-level windows but do not accept status-item reordering.
        return !reservedTitles.contains { window.title == $0 || window.title.hasPrefix("\($0)-") }
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

private extension CGEventFilterMask {
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
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
