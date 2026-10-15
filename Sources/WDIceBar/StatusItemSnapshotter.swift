import AppKit
import ApplicationServices
import CoreGraphics

struct StatusItemSnapshot: Identifiable {
    let id: CGWindowID
    /// Best-effort identity for the current menu-bar session. `windowID` is the authoritative
    /// key while the item exists; this value helps preserve an editor selection after a refresh.
    let key: String
    /// Bundle ID and window title survive process restarts; unnamed items are session-only.
    let exclusionKey: String?
    let image: NSImage
    let label: String
    var usesApplicationIcon = false
    var usesUnavailableImage = false
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
        case userInputBusy

        var description: String {
            switch self {
            case .moved: "已移动"
            case .accessibilityDenied: "辅助功能权限不可用"
            case .sourceOrTargetMissing: "移动期间找不到源图标或分隔标记"
            case .eventRouting(let result): result.description
            case .positionNotConfirmed: "事件已送达，但 1.5 秒内未确认到新的相邻位置"
            case .userInputBusy: "检测到鼠标按住或持续移动，暂不自动拖拽，请松开后重试"
            }
        }
    }

    private let eventRouter = MenuBarEventRouter()
    var testItemImages: [String: NSImage] = [:]
    private var rememberedWindows: [CGWindowID: StatusWindow] = [:]
    private struct RememberedSnapshot {
        let ownerPID: pid_t
        let title: String
        let snapshot: StatusItemSnapshot
    }
    private var rememberedSnapshots: [CGWindowID: RememberedSnapshot] = [:]
    func capture(
        excluding ownPID: pid_t,
        excludingTitles: Set<String>,
        maximumX: CGFloat?,
        includingOverflowOutside visibleBounds: CGRect? = nil
    ) -> [StatusItemSnapshot] {
        return statusItemWindows()
            .filter { window in
                // NSStatusItem windows are hosted by Control Center on modern macOS, so their
                // owner PID is not this app. Exclude our own two items by both possible signals.
                guard (window.ownerPID != ownPID || testItemImages[window.title] != nil), !excludingTitles.contains(window.title) else {
                    return false
                }

                guard StatusItemWindowCatalog.isUserMenuBarItem(window) else { return false }

                guard let maximumX else { return true }
                return StatusItemWindowCatalog.belongsInShelf(window.frame, boundaryX: maximumX, visibleBounds: visibleBounds)
            }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { window in
                let captured = CGWindowListCreateImage(
                    .null, .optionIncludingWindow, window.id, [.boundsIgnoreFraming, .bestResolution]
                )
                let image: NSImage
                let usesApplicationIcon: Bool
                let usesUnavailableImage: Bool
                let old = rememberedSnapshots[window.id].flatMap {
                    $0.ownerPID == window.ownerPID && $0.title == window.title ? $0.snapshot : nil
                }
                if let testImage = testItemImages[window.title] {
                    // These images belong to explicitly created native test items. They
                    // are not fallback guesses for unknown third-party windows.
                    image = testImage
                    usesApplicationIcon = false
                    usesUnavailableImage = false
                } else if let captured, hasMeaningfulIconPixels(captured) {
                    image = NSImage(cgImage: captured, size: window.frame.size)
                    usesApplicationIcon = false
                    usesUnavailableImage = false
                } else if let old, !old.usesUnavailableImage {
                    image = old.image
                    usesApplicationIcon = old.usesApplicationIcon
                    usesUnavailableImage = false
                } else if let bundleID = window.itemBundleID,
                          let appIcon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon?.copy() as? NSImage {
                    // Retain the actual item identity when off-screen surfaces cannot be
                    // captured. Never substitute a host initial or invent an unknown app.
                    appIcon.size = NSSize(width: 24, height: 24)
                    image = appIcon
                    usesApplicationIcon = true
                    usesUnavailableImage = false
                } else {
                    // This is a verified real window, not a guessed application. Do not
                    // erase it just because a single-display host cannot supply an image.
                    image = NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: "图像暂不可用") ?? NSImage(size: NSSize(width: 24, height: 24))
                    image.size = NSSize(width: 24, height: 24)
                    usesApplicationIcon = false
                    usesUnavailableImage = true
                }
                let snapshot = StatusItemSnapshot(
                    id: window.id,
                    key: "\(window.ownerPID)|\(window.itemBundleID ?? window.ownerName)|\(window.title)",
                    exclusionKey: testItemImages[window.title] != nil ? nil : window.exclusionKey,
                    image: image,
                    label: usesUnavailableImage ? "菜单项 #\(window.id)（应用身份及图像暂不可用）" : itemLabel(for: window),
                    usesApplicationIcon: usesApplicationIcon,
                    usesUnavailableImage: usesUnavailableImage
                )
                rememberedSnapshots[window.id] = RememberedSnapshot(ownerPID: window.ownerPID, title: window.title, snapshot: snapshot)
                return snapshot
            }
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

    /// Layout changes require confirmed adjacency. Temporary activation can instead
    /// accept any stable visible position, without rearranging an already clickable item.
    @discardableResult
    func move(windowID: CGWindowID, beside targetID: CGWindowID, onRight: Bool,
              acceptingVisibleFrameIn bounds: CGRect? = nil, restoreCursorPosition: Bool = true) async -> MoveResult {
        guard accessibilityIsTrusted(prompting: true) else { return .accessibilityDenied }
        guard await waitForPointerIdle() else { return .userInputBusy }
        let cursor = MenuBarCursorGuard(hideCursor: false)
        defer { cursor.finish(restorePosition: restoreCursorPosition) }

        var lastRoutingFailure: MenuBarEventRouter.Result?
        for _ in 0..<3 {
            // Activation needs a clickable item, not a particular neighbour.
            // Do not drag again if the previous attempt already exposed it.
            if let bounds, let frame = windowFrame(for: windowID), bounds.contains(frame),
               await waitForVisibleFrame(of: windowID, within: bounds) { return .moved }
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
            let routingResult = await postCommandDrag(item: item, target: target, destination: destination,
                source: source, restoreCursorPosition: restoreCursorPosition)
            guard routingResult == .delivered else {
                lastRoutingFailure = routingResult
                try? await Task.sleep(for: .milliseconds(80))
                continue
            }

            let confirmed: Bool
            if let bounds {
                confirmed = await waitForVisibleFrame(of: windowID, within: bounds)
            } else {
                confirmed = await waitForAdjacency(of: windowID, beside: targetID, onRight: onRight)
            }
            if confirmed {
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

    func testItemSummary(boundaryX: CGFloat?, visibleBounds: CGRect?) -> String {
        let windows = statusItemWindows().filter { testItemImages[$0.title] != nil }
        let overflow = windows.filter { window in
            guard let visibleBounds, let boundaryX else { return false }
            return window.frame.minX >= boundaryX && !visibleBounds.contains(window.frame)
        }
        return "识别到 \(windows.count) 个真实测试项；其中 \(overflow.count) 个在可见分组一侧自然溢出。"
    }

    func hiddenBoundaryX(titled title: String) -> CGFloat? {
        statusItemWindows().first { $0.title == title }?.frame.minX
    }

    func isWindow(_ windowID: CGWindowID, toRightOf dividerID: CGWindowID) -> Bool? {
        guard let itemFrame = windowFrame(for: windowID), let dividerFrame = windowFrame(for: dividerID) else {
            return nil
        }
        return itemFrame.minX >= dividerFrame.maxX - 1
    }

    /// Reveals an original status item briefly, then sends it the same mouse click a user would.
    /// macOS requires Accessibility permission for synthesized input, so the first click can
    /// display the system permission prompt instead of silently doing nothing.
    @discardableResult
    func click(windowID: CGWindowID, mouseButton: CGMouseButton, promptingForAccessibility: Bool,
               preserveCursorPosition: Bool = false, within bounds: CGRect? = nil) async -> Bool {
        guard accessibilityIsTrusted(prompting: promptingForAccessibility),
              let item = statusWindow(for: windowID),
              bounds?.contains(item.frame) ?? true,
              let source = CGEventSource(stateID: .hidSystemState)
        else {
            return false
        }

        let cursor = MenuBarCursorGuard()
        var restoreCursor = true
        defer { cursor.finish(restorePosition: restoreCursor) }
        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        guard let down = menuBarEvent(type: mouseButton == .right ? .rightMouseDown : .leftMouseDown,
                                      location: point, targetWindowID: item.id, ownerPID: item.ownerPID,
                                      source: source, flags: []),
              let up = menuBarEvent(type: mouseButton == .right ? .rightMouseUp : .leftMouseUp,
                                    location: point, targetWindowID: item.id, ownerPID: item.ownerPID,
                                    source: source, flags: []) else { return false }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        guard await eventRouter.route(down, to: item.ownerPID) == .delivered else { return false }
        let result = await eventRouter.route(up, to: item.ownerPID)
        // Session routing completes before the host finishes processing mouse-up.
        try? await Task.sleep(for: .milliseconds(40))
        if result == .delivered {
            // Native menus may track the cursor. Returning to the dismissed proxy
            // immediately can close the newly opened menu. Keep it at the real item.
            restoreCursor = preserveCursorPosition
        }
        return result == .delivered
    }

    struct TemporaryPlacement {
        let windowID: CGWindowID
        let returnAnchorID: CGWindowID
        let onRight: Bool
    }

    enum RevealResult {
        case ready(TemporaryPlacement?)
        case failed(String)
    }

    func revealForClick(windowID: CGWindowID, within bounds: CGRect, keepingCursorAtItem: Bool = false) async -> RevealResult {
        let windows = statusItemWindows().sorted { $0.frame.minX < $1.frame.minX }
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return .failed("找不到原生菜单项") }
        let item = windows[index]
        if bounds.contains(item.frame) { return .ready(nil) }
        let neighbor: StatusWindow
        let onRight: Bool
        if windows.indices.contains(index + 1) {
            neighbor = windows[index + 1]
            onRight = false
        } else if windows.indices.contains(index - 1) {
            neighbor = windows[index - 1]
            onRight = true
        } else { return .failed("无法记录原位置") }
        guard let target = StatusItemWindowCatalog.revealAnchor(for: item, in: windows, bounds: bounds) else {
            return .failed("没有可用位置容纳该图标")
        }
        let placement = TemporaryPlacement(windowID: item.id, returnAnchorID: neighbor.id, onRight: onRight)
        let result = await move(windowID: item.id, beside: target.id, onRight: false,
            acceptingVisibleFrameIn: bounds, restoreCursorPosition: !keepingCursorAtItem)
        if result == .moved, let frame = windowFrame(for: item.id), bounds.contains(frame) {
            return .ready(placement)
        }
        // Even a failed confirmation may have changed the physical layout.
        _ = await restore(placement)
        return .failed("无法将目标移入可见区域：\(result.description)")
    }

    func restore(_ placement: TemporaryPlacement) async -> MoveResult {
        await move(windowID: placement.windowID, beside: placement.returnAnchorID, onRight: placement.onRight)
    }

    func isTestWindow(_ windowID: CGWindowID) -> Bool {
        guard let item = statusWindow(for: windowID) else { return false }
        return testItemImages[item.title] != nil
    }

    /// Cache only frames that did not move while the asynchronous screenshot ran;
    /// otherwise a changed layout could assign another item's pixels to this ID.
    @discardableResult
    func cacheVisibleImages(displayID: CGDirectDisplayID, bounds: CGRect? = nil) async -> Int {
        let windows = statusItemWindows().filter { StatusItemWindowCatalog.isUserMenuBarItem($0) && (bounds?.contains($0.frame) ?? true) }
        let images = await StatusItemScreenCapture.capture(windows: windows, displayID: displayID)
        let current = Dictionary(uniqueKeysWithValues: statusItemWindows().map { ($0.id, $0) })
        var count = 0
        for window in windows {
            guard let image = images[window.id], let latest = current[window.id],
                  latest.frame == window.frame, latest.ownerPID == window.ownerPID, latest.title == window.title else { continue }
            let snapshot = StatusItemSnapshot(id: window.id,
                key: "\(window.ownerPID)|\(window.itemBundleID ?? window.ownerName)|\(window.title)",
                exclusionKey: window.exclusionKey, image: image, label: itemLabel(for: window))
            rememberedSnapshots[window.id] = RememberedSnapshot(ownerPID: window.ownerPID, title: window.title, snapshot: snapshot)
            count += 1
        }
        return count
    }

    func recoverMissingImages(excluding ownPID: pid_t, excludingTitles: Set<String>, bounds: CGRect, displayID: CGDirectDisplayID) async {
        _ = await cacheVisibleImages(displayID: displayID, bounds: bounds)
        guard AXIsProcessTrusted(), ScreenCapturePermission.isGranted else { return }
        let missing = captureAllCandidates(excluding: ownPID, excludingTitles: excludingTitles)
            .filter { $0.usesUnavailableImage || $0.usesApplicationIcon }
        for item in missing {
            guard !Task.isCancelled else { return }
            switch await revealForClick(windowID: item.id, within: bounds) {
            case .failed: continue
            case .ready(let placement):
                try? await Task.sleep(for: .milliseconds(100))
                _ = await cacheVisibleImages(displayID: displayID, bounds: bounds)
                if let placement { _ = await restore(placement) }
            }
        }
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

        let windows = descriptions.compactMap { description -> StatusWindow? in
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
            return StatusWindow(id: id, ownerPID: ownerPID, ownerName: ownerName,
                                ownerBundleID: NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier,
                                title: title, frame: frame)
        }
        let real = StatusItemWindowCatalog.realWindows(windows, screenWidths: NSScreen.screens.map { $0.frame.width })
        let restored = StatusItemWindowCatalog.preservingIdentities(real, previous: rememberedWindows)
        if !restored.isEmpty {
            rememberedWindows = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
            rememberedSnapshots = rememberedSnapshots.filter { id, old in
                guard let current = rememberedWindows[id] else { return false }
                return current.ownerPID == old.ownerPID && current.title == old.title
            }
        }
        return restored
    }

    private func itemLabel(for window: StatusWindow) -> String {
        if testItemImages[window.title] != nil, let number = Int(window.title.split(separator: ".").last ?? "") {
            return String(format: "溢出验证 T%02d", number)
        }
        if let bundleID = window.itemBundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
        }
        return window.title.isEmpty ? window.ownerName : window.title
    }

    private func statusWindow(for windowID: CGWindowID) -> StatusWindow? {
        statusItemWindows().first { $0.id == windowID }
    }

    private func postCommandDrag(
        item: StatusWindow,
        target: StatusWindow,
        destination: CGPoint,
        source: CGEventSource,
        restoreCursorPosition: Bool
    ) async -> MenuBarEventRouter.Result {
        let gestureCursor = MenuBarCursorGuard()
        defer { gestureCursor.finish(restorePosition: restoreCursorPosition) }
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
            mouseButton: (type == .rightMouseDown || type == .rightMouseUp) ? .right : .left
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

    struct VisiblePlacement {
        let bounds: CGRect
        private var previousFrame: CGRect?

        init(bounds: CGRect) { self.bounds = bounds }

        mutating func observe(_ frame: CGRect?) -> Bool {
            guard let frame, frame.width > 0, frame.height > 0,
                  abs(frame.minY - bounds.minY) <= 1, bounds.contains(frame) else {
                previousFrame = nil
                return false
            }
            defer { previousFrame = frame }
            return previousFrame == frame
        }
    }

    private func waitForVisibleFrame(of windowID: CGWindowID, within bounds: CGRect) async -> Bool {
        var placement = VisiblePlacement(bounds: bounds)
        for _ in 0..<60 {
            guard !Task.isCancelled else { return false }
            if placement.observe(windowFrame(for: windowID)) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func waitForAdjacency(of windowID: CGWindowID, beside targetID: CGWindowID, onRight: Bool) async -> Bool {
        var previousAdjacentFrames: (item: CGRect, target: CGRect)?
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
                    // A first matching position may still be a drag/reflow frame.
                    // Two identical observations allow clicking immediately after
                    // confirmation without a separate fixed activation delay.
                    if let previousAdjacentFrames,
                       previousAdjacentFrames.item == itemFrame,
                       previousAdjacentFrames.target == targetFrame { return true }
                    previousAdjacentFrames = (itemFrame, targetFrame)
                } else {
                    previousAdjacentFrames = nil
                }
            } else {
                previousAdjacentFrames = nil
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

    func windowFrame(for windowID: CGWindowID) -> CGRect? {
        var rawID = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let array = CFArrayCreate(kCFAllocatorDefault, &rawID, 1, nil),
              let description = (CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]])?.first,
              let bounds = description[kCGWindowBounds] as? NSDictionary
        else {
            return nil
        }
        return CGRect(dictionaryRepresentation: bounds)
    }

    private func waitForPointerIdle() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let held = CGEventSource.buttonState(.combinedSessionState, button: .left) ||
                CGEventSource.buttonState(.combinedSessionState, button: .right)
            let recentlyMoved = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved) < 0.15 ||
                CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDragged) < 0.15
            if !held, !recentlyMoved { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
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
