import AppKit
import ServiceManagement

/// The deliberately small state machine behind the app: the divider hides native items while
/// the panel shows their captured appearance.
@MainActor
final class MenuBarController: NSObject {
    private enum IconChoice: String, CaseIterable {
        case grid, arrow, chevron, door, dot, ellipsis, iceCube, sunglasses

        var title: String {
            switch self {
            case .grid: "Grid"
            case .arrow: "Arrow"
            case .chevron: "Chevron"
            case .door: "Door"
            case .dot: "Dot"
            case .ellipsis: "Ellipsis"
            case .iceCube: "Ice Cube"
            case .sunglasses: "Sunglasses"
            }
        }

        func symbolName(isHidden: Bool) -> String {
            switch self {
            case .grid: "rectangle.3.group.fill"
            case .arrow: isHidden ? "arrowshape.left.fill" : "arrowshape.right.fill"
            case .chevron: isHidden ? "chevron.left" : "chevron.right"
            case .door: isHidden ? "door.left.hand.closed" : "door.left.hand.open"
            case .dot: isHidden ? "circle.fill" : "circle"
            case .ellipsis: isHidden ? "ellipsis.circle.fill" : "ellipsis.circle"
            case .iceCube: isHidden ? "snowflake" : "cube"
            case .sunglasses: isHidden ? "sunglasses.fill" : "sunglasses"
            }
        }
    }

    private enum ItemName {
#if MENU_BAR_INTEGRATION
        static let trigger = "WDClickIntegration.Toggle"
        static let divider = "WDClickIntegration.Divider"
#else
        static let trigger = "WDIceBar.Toggle.v1"
        static let divider = "WDIceBar.Divider.v1"
#endif
    }

    private enum State {
        case hidden
        case shown
        case arranging
    }

    private let dividerItem: NSStatusItem
    private let triggerItem: NSStatusItem
    private let snapshotter = StatusItemSnapshotter()
    private let panel = HiddenItemsPanel()
    private let exclusions = StatusItemExclusions()
    private let overflowTest = MenuBarOverflowTest()
    private let controlHotKey = MenuBarHotKey()
    private var cachedSnapshots: [StatusItemSnapshot] = []
    private var outsideClickMonitor: Any?
    private var nativeMenuTracker: MenuBarNativeMenuTracker?
    private var nativeContextMenuIsOpen = false
    private var activationTask: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?
    private var temporaryPlacement: StatusItemSnapshotter.TemporaryPlacement?
    private var isActivatingNativeItem = false
    private var receivedNativeTestClick = false
    private var localClickMonitor: Any?
    private var dismissalGeneration: UInt64 = 0
    private var imageRecoveryTask: Task<Void, Never>?
    private var isRecoveringImages = false
    private var attemptedImageRecovery: Set<CGWindowID> = []
    private var layoutTask: Task<Void, Never>?
    private var isApplyingLayout = false
    private var iconChoice: IconChoice {
        get { IconChoice(rawValue: UserDefaults.standard.string(forKey: "WDIceBar.IconChoice") ?? "") ?? .grid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "WDIceBar.IconChoice") }
    }

    private var state: State = .shown

    override init() {
        // Mirror Ice's first-run placement: position 0 remains visible as the toggle, while
        // position 1 is the transparent divider immediately to its left.
        let defaults = UserDefaults.standard
        let triggerKey = "NSStatusItem Preferred Position \(ItemName.trigger)"
        let dividerKey = "NSStatusItem Preferred Position \(ItemName.divider)"
        if defaults.object(forKey: triggerKey) == nil { defaults.set(0, forKey: triggerKey) }
        if defaults.object(forKey: dividerKey) == nil { defaults.set(1, forKey: dividerKey) }

        dividerItem = NSStatusBar.system.statusItem(withLength: 1)
        triggerItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
    }

    func start() {
        overflowTest.insertionPosition = {
            UserDefaults.standard.integer(forKey: "NSStatusItem Preferred Position \(ItemName.trigger)") + 1
        }
        overflowTest.shortcutAvailable = controlHotKey.register { [weak self] in self?.showControlWindow() }
        overflowTest.onChange = { [weak self] images in
            guard let self else { return }
            self.snapshotter.testItemImages = images
            self.cachedSnapshots.removeAll { $0.key.contains("WDIceBar.Test.") }
        }
        overflowTest.onNativeReceipt = { [weak self] in
            guard let self else { return }
            self.receivedNativeTestClick = true
            if !self.isActivatingNativeItem, self.nativeContextMenuIsOpen { self.hideNativeItems() }
        }
        overflowTest.onMeasure = { [weak self] in
            guard let self else { return "" }
            return self.snapshotter.testItemSummary(
                boundaryX: self.snapshotter.hiddenBoundaryX(titled: ItemName.divider),
                visibleBounds: self.menuBarVisibleBounds()
            )
        }
        overflowTest.onShowVirtualMenu = { [weak self] in
            guard let self else { return }
            self.refreshSnapshotCache()
            self.showPanel()
        }
        configureTrigger()
        configureDivider()
        // Capture while native status items are still on-screen. Later taps can show this
        // cached representation directly, avoiding the distracting reveal-then-hide flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
            self?.captureThenFinish(showPanelAfter: false, recoverMissing: false)
        }
    }

    func restoreBeforeTermination() async {
        if let imageRecoveryTask { await imageRecoveryTask.value }
        if let activationTask { await activationTask.value }
        if let restorationTask { await restorationTask.value }
        if let placement = temporaryPlacement {
            temporaryPlacement = nil
            _ = await snapshotter.restore(placement)
        }
    }

    func stop() {
        imageRecoveryTask?.cancel()
        activationTask?.cancel()
        restorationTask?.cancel()
        stopOutsideClickMonitor()
        nativeMenuTracker?.stop()
        nativeMenuTracker = nil
        controlHotKey.unregister()
        overflowTest.clear()
        NSStatusBar.system.removeStatusItem(triggerItem)
        NSStatusBar.system.removeStatusItem(dividerItem)
    }

    private func configureTrigger() {
        triggerItem.autosaveName = ItemName.trigger
        guard let button = triggerItem.button else { return }
        updateTriggerIcon(isHidden: true)
        button.toolTip = "Show hidden menu bar items"
        button.target = self
        button.action = #selector(toggle)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureDivider() {
        dividerItem.autosaveName = ItemName.divider
        dividerItem.button?.image = nil
        dividerItem.button?.isEnabled = false
    }

    @objc private func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Build the menu just before it opens so both the icon selection and login-item
            // status always reflect the current system state.
            makeContextMenu().popUp(positioning: nil, at: .zero, in: triggerItem.button)
            return
        }

        switch state {
        case .hidden:
            showPanel()
        case .shown:
            panel.close()
            hideNativeItems()
        case .arranging:
            refreshSnapshotCache()
            hideNativeItems()
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let arrange = NSMenuItem(
            title: "调整菜单显隐",
            action: #selector(enterArrangementMode),
            keyEquivalent: ""
        )
        arrange.target = self
        menu.addItem(arrange)

        let systemSettings = NSMenuItem(title: "打开系统菜单管理", action: #selector(openMenuBarSettings), keyEquivalent: "")
        systemSettings.target = self
        menu.addItem(systemSettings)

        let refresh = NSMenuItem(
            title: "刷新应用",
            action: #selector(refreshHiddenItems),
            keyEquivalent: ""
        )
        refresh.target = self
        menu.addItem(refresh)

        let restore = NSMenuItem(title: "恢复已移除的虚拟菜单项", action: #selector(restoreExcludedItems), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = exclusions.hasExclusions
        menu.addItem(restore)

        let test = NSMenuItem(title: "菜单栏溢出验证…", action: #selector(showOverflowTest), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let icons = NSMenu(title: "更换图标")
        for choice in IconChoice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectIcon), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == iconChoice ? .on : .off
            item.image = NSImage(systemSymbolName: choice.symbolName(isHidden: true), accessibilityDescription: choice.title)
            icons.addItem(item)
        }
        let iconMenuItem = NSMenuItem(title: "更换图标", action: nil, keyEquivalent: "")
        iconMenuItem.submenu = icons
        menu.addItem(iconMenuItem)

        let launchAtLogin = NSMenuItem(
            title: "开机启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin.state = .on
        case .requiresApproval:
            launchAtLogin.state = .mixed
            launchAtLogin.toolTip = "已请求开机启动，请在系统设置中确认"
        default:
            launchAtLogin.state = .off
        }
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func enterArrangementMode() {
        guard !isApplyingLayout, !isRecoveringImages else { return }
        panel.dismissForLayoutTransaction()
        // Restore the genuine layout before capturing candidates. Unlike the normal adjustment
        // mode, the editor can show candidates that are currently beyond the screen edge.
        dividerItem.length = 16
        dividerItem.button?.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Hidden item boundary")
        dividerItem.button?.image?.isTemplate = true
        dividerItem.button?.isEnabled = true
        triggerItem.button?.toolTip = "编辑中：在下方栏拖动图标，蓝线左侧显示、右侧隐藏"
        state = .arranging
        startOutsideClickMonitor()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) { [weak self] in
            self?.presentArrangementEditor()
        }
    }

    func showControlWindow() { overflowTest.show() }

    @objc private func showOverflowTest() { showControlWindow() }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func openMenuBarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshHiddenItems() {
        attemptedImageRecovery.removeAll()
        captureThenFinish(showPanelAfter: false, recoverMissing: true, returnToArrangement: state == .arranging)
    }

    private func captureThenFinish(showPanelAfter: Bool, recoverMissing: Bool, returnToArrangement: Bool = false) {
        guard !isRecoveringImages, !isActivatingNativeItem, restorationTask == nil else { return }
        isRecoveringImages = true
        stopOutsideClickMonitor()
        if !returnToArrangement { dividerItem.length = 1; state = .shown }
        imageRecoveryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(180))
            if let screen = self.panel.screen ?? self.triggerItem.button?.window?.screen ?? NSScreen.main,
               let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               let bounds = self.menuBarVisibleBounds(on: screen) {
                if recoverMissing {
                    await self.snapshotter.recoverMissingImages(excluding: getpid(),
                        excludingTitles: [ItemName.divider, ItemName.trigger], bounds: bounds, displayID: number.uint32Value)
                } else {
                    _ = await self.snapshotter.cacheVisibleImages(displayID: number.uint32Value, bounds: bounds)
                }
            }
            self.refreshSnapshotCache()
            self.attemptedImageRecovery.formUnion(self.cachedSnapshots.filter { $0.usesUnavailableImage || $0.usesApplicationIcon }.map(\.id))
            self.isRecoveringImages = false
            self.imageRecoveryTask = nil
            if returnToArrangement {
                self.presentArrangementEditor()
                self.startOutsideClickMonitor()
            } else if showPanelAfter {
                self.dividerItem.length = 10_000
                self.showPanel(refreshingEmptyCache: false)
            } else {
                self.hideNativeItems()
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法更新开机启动设置"
            alert.runModal()
        }
    }

    @objc private func selectIcon(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let choice = IconChoice(rawValue: rawValue) else { return }
        iconChoice = choice
        updateTriggerIcon(isHidden: state == .hidden)
    }

    private func hideNativeItems() {
        guard !isActivatingNativeItem, !isRecoveringImages, restorationTask == nil else { return }
        nativeContextMenuIsOpen = false
        nativeMenuTracker?.stop()
        nativeMenuTracker = nil
        if let placement = temporaryPlacement {
            temporaryPlacement = nil
            stopOutsideClickMonitor()
            restorationTask = Task { [weak self] in
                guard let self else { return }
                let result = await self.snapshotter.restore(placement)
                self.restorationTask = nil
                self.hideNativeItems()
                if result != .moved, result != .sourceOrTargetMissing {
                    self.reportActivationFailure("点击后未能恢复原位置：\(result.description)")
                }
            }
            return
        }
        layoutTask?.cancel()
        layoutTask = nil
        isApplyingLayout = false
        panel.close()
        stopOutsideClickMonitor()
        // Ice uses the same approach: a transparent, wide status item moves the items after it
        // out of the visible menu bar. Keep the control item to the divider's left in the status
        // bar; macOS remembers that position through autosaveName.
        dividerItem.button?.image = nil
        dividerItem.button?.isEnabled = false
        dividerItem.length = 10_000
        triggerItem.button?.toolTip = "显示隐藏的菜单栏图标（右键可调整）"
        updateTriggerIcon(isHidden: true)
        state = .hidden
    }

    private func showPanel(refreshingEmptyCache: Bool = true) {
        guard !isRecoveringImages else { return }
        let missing = Set(cachedSnapshots.filter { $0.usesUnavailableImage || $0.usesApplicationIcon }.map(\.id))
        if refreshingEmptyCache, cachedSnapshots.isEmpty || !missing.subtracting(attemptedImageRecovery).isEmpty {
            captureThenFinish(showPanelAfter: true, recoverMissing: true)
            return
        }
        panel.show(
            snapshots: cachedSnapshots.filter { !exclusions.contains($0) },
            onRemove: { [weak self] snapshot in self?.removeSnapshot(snapshot) },
            onClose: { [weak self] in self?.hideNativeItems() },
            onActivate: { [weak self] windowID, mouseButton in self?.activateNativeItem(windowID, mouseButton: mouseButton) }
        )
        state = .shown
        updateTriggerIcon(isHidden: false)
        startOutsideClickMonitor()
    }

    private func presentArrangementEditor() {
        guard state == .arranging,
              let dividerID = snapshotter.statusItemWindowID(titled: ItemName.divider)
        else {
            hideNativeItems()
            return
        }

        let allCandidates = snapshotter.captureAllCandidates(
            excluding: getpid(),
            excludingTitles: [ItemName.divider, ItemName.trigger]
        ).filter { !exclusions.contains($0) }
        guard !allCandidates.isEmpty else {
            hideNativeItems()
            return
        }

        // The editor's visual order is intentionally different from physical order: the user
        // requested that icons left of the blue marker are visible. Physically those items live
        // to the divider's right, while the hidden shelf lives on its left.
        let visible = allCandidates.filter { snapshotter.isWindow($0.id, toRightOf: dividerID) == true }
        let hidden = allCandidates.filter { snapshotter.isWindow($0.id, toRightOf: dividerID) != true }
        panel.showArrangement(
            snapshots: visible + hidden,
            visibleCount: visible.count,
            onRemove: { [weak self] snapshot in self?.removeSnapshot(snapshot) },
            onCommit: { [weak self] snapshots, visibleCount in
                self?.applyArrangement(snapshots, visibleCount: visibleCount)
            },
            onClose: { [weak self] in self?.hideNativeItems() }
        )
    }

    private func applyArrangement(_ snapshots: [StatusItemSnapshot], visibleCount: Int) {
        guard !isApplyingLayout,
              let dividerID = snapshotter.statusItemWindowID(titled: ItemName.divider)
        else { return }

        isApplyingLayout = true
        panel.setArrangementCommitLocked(true)
        let visible = Array(snapshots.prefix(visibleCount))
        let hidden = Array(snapshots.dropFirst(visibleCount))

        // The editor describes a desired visibility split. Only items that actually cross the
        // divider need a native ⌘ drag. Re-dragging every already-correct item was both noisy
        // and could stop the transaction on a non-movable item before the user's real change.
        let visibleToMove = visible.filter { snapshotter.isWindow($0.id, toRightOf: dividerID) != true }
        let hiddenToMove = hidden.filter { snapshotter.isWindow($0.id, toRightOf: dividerID) == true }

        layoutTask?.cancel()
        layoutTask = Task { [weak self, snapshotter] in
            var completed = true
            var failureDescription: String?

            // The mouse-up that ends the proxy drag can otherwise race the first synthesized
            // native ⌘ drag. Ice waits until real user input has settled before moving items.
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }

            // Inserting each list in reverse retains its left-to-right order next to the same
            // divider. A proxy drag therefore has the exact visual order chosen in the editor.
            for snapshot in visibleToMove.reversed() {
                guard !Task.isCancelled else { return }
                let result = await snapshotter.move(windowID: snapshot.id, beside: dividerID, onRight: true)
                if result != .moved {
                    completed = false
                    failureDescription = "\(snapshot.label)：\(result.description)"
                    break
                }
            }
            if completed {
                for snapshot in hiddenToMove.reversed() {
                    guard !Task.isCancelled else { return }
                    let result = await snapshotter.move(windowID: snapshot.id, beside: dividerID, onRight: false)
                    if result != .moved {
                        completed = false
                        failureDescription = "\(snapshot.label)：\(result.description)"
                        break
                    }
                }
            }

            guard let self, !Task.isCancelled else { return }
            self.isApplyingLayout = false
            self.layoutTask = nil
            self.refreshSnapshotCache()
            self.panel.setArrangementCommitLocked(false)

            if !completed {
                let alert = NSAlert()
                alert.messageText = "部分图标未能移动"
                alert.informativeText = "\(failureDescription ?? "无法确认移动结果")。已停止余下移动；可再次进入编辑模式查看当前顺序并重试。"
                alert.runModal()
            }
        }
    }

    private func startOutsideClickMonitor() {
        installLocalDismissMonitor()
        guard outsideClickMonitor == nil else { return }
        let generation = dismissalGeneration
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .mouseMoved, .keyDown]) { [weak self] event in
            // Routed input can arrive after activation finishes. Never treat our
            // synthetic click/drag as a user dismissing the menu it just opened.
            guard MenuBarDismissalPolicy.isUserInput(event.cgEvent) else { return }
            DispatchQueue.main.async {
                guard let self, self.dismissalGeneration == generation,
                      !self.isActivatingNativeItem, !self.isRecoveringImages else { return }
                if event.type == .keyDown, event.keyCode != 53 { return }
                if event.type == .mouseMoved {
                    if self.nativeContextMenuIsOpen, let point = event.cgEvent?.location {
                        self.nativeMenuTracker?.observePointerMovement(at: point)
                    }
                    return
                }
                switch self.state {
                case .shown:
                    if self.nativeContextMenuIsOpen {
                        // Wait for the user's mouse-up, never interrupt a held
                        // click or treat our forwarded click as dismissal.
                        guard event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .keyDown else { return }
                        self.requestNativeDismissal(at: event.type == .keyDown ? nil : event.cgEvent?.location)
                    } else {
                        guard event.type != .leftMouseUp, event.type != .rightMouseUp else { return }
                        self.panel.close()
                    }
                case .arranging where self.isNativeMenuBarClick():
                    guard event.type != .leftMouseUp, event.type != .rightMouseUp else { return }
                    self.hideNativeItems()
                case .hidden, .arranging:
                    break
                }
            }
        }
    }

    private func installLocalDismissMonitor() {
        guard localClickMonitor == nil else { return }
        let generation = dismissalGeneration
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .mouseMoved, .keyDown]) { [weak self] event in
            guard MenuBarDismissalPolicy.isUserInput(event.cgEvent) else { return event }
            if let self, self.dismissalGeneration == generation, !self.isActivatingNativeItem, !self.isRecoveringImages, self.nativeContextMenuIsOpen,
               event.window !== self.panel, (event.type != .keyDown || event.keyCode == 53) {
                if event.type == .mouseMoved, let point = event.cgEvent?.location {
                    self.nativeMenuTracker?.observePointerMovement(at: point)
                } else {
                    self.requestNativeDismissal(at: event.type == .keyDown ? nil : event.cgEvent?.location)
                }
            }
            return event
        }
    }

    private func requestNativeDismissal(at point: CGPoint?) {
        if let nativeMenuTracker {
            nativeMenuTracker.requestDismissal(at: point)
        } else {
            hideNativeItems()
        }
    }

    private func isNativeMenuBarClick() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        return point.y >= screen.frame.maxY - NSStatusBar.system.thickness
    }

    private func stopOutsideClickMonitor() {
        dismissalGeneration &+= 1
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func updateTriggerIcon(isHidden: Bool) {
        guard let button = triggerItem.button else { return }
        button.image = NSImage(
            systemSymbolName: iconChoice.symbolName(isHidden: isHidden),
            accessibilityDescription: "Show hidden menu bar items"
        )
        button.image?.isTemplate = true
    }

    private func menuBarVisibleBounds(on preferredScreen: NSScreen? = nil) -> CGRect? {
        guard let screen = preferredScreen ?? triggerItem.button?.window?.screen ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let display = CGDisplayBounds(number.uint32Value)
        // On a notched display, status items must fit in the area to the notch's right.
        let area = screen.auxiliaryTopRightArea
        return CGRect(x: area?.minX ?? display.minX, y: display.minY,
                      width: area?.width ?? display.width, height: display.height)
    }

    private func refreshSnapshotCache() {
        // A missing AppKit window used to pass nil and capture the entire menu bar.
        // Read the boundary from the same WindowServer coordinate space as the items.
        guard let maximumX = snapshotter.hiddenBoundaryX(titled: ItemName.divider) else { return }
        let snapshots = snapshotter.capture(
            excluding: getpid(),
            excludingTitles: [ItemName.divider, ItemName.trigger],
            maximumX: maximumX,
            includingOverflowOutside: menuBarVisibleBounds()
        )
        // Preserve a cache only for a genuinely empty WindowServer scan. An exclusion
        // that removes the final candidate must also be allowed to empty the shelf.
        if !snapshots.isEmpty {
            cachedSnapshots = snapshots.filter { !exclusions.contains($0) }
        } else {
            cachedSnapshots.removeAll { exclusions.contains($0) }
        }
    }

    private func removeSnapshot(_ snapshot: StatusItemSnapshot) {
        guard !isApplyingLayout else { return }
        exclusions.insert(snapshot)
        cachedSnapshots.removeAll { exclusions.contains($0) }
        if state == .arranging {
            presentArrangementEditor()
        } else if state == .shown {
            showPanel()
        }
    }

    @objc private func restoreExcludedItems() {
        exclusions.reset()
        if state == .arranging {
            presentArrangementEditor()
        } else {
            refreshHiddenItems()
        }
    }

    private func reportActivationFailure(_ message: String) {
#if MENU_BAR_INTEGRATION
        print("ACTIVATION_FAILURE \(message)")
#else
        if overflowTest.isActive {
            overflowTest.reportFailure(message)
        } else {
            let alert = NSAlert()
            alert.messageText = "无法打开原生菜单项"
            alert.informativeText = message
            alert.runModal()
        }
#endif
    }

    private func activateNativeItem(_ windowID: CGWindowID, mouseButton: CGMouseButton) {
        guard !isActivatingNativeItem, !isRecoveringImages, restorationTask == nil else { return }
        // Keep the wide divider in place: move only this item across it and
        // retain its original neighbour so dismissal restores the hidden group.
        let preferredScreen = panel.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        stopOutsideClickMonitor()
        state = .shown
        isActivatingNativeItem = true
        receivedNativeTestClick = false
        let isTest = snapshotter.isTestWindow(windowID)

        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let cursor = MenuBarCursorGuard(hideCursor: false)
            var restoreCursor = true
            defer { cursor.finish(restorePosition: restoreCursor) }
            // The proxy closes synchronously before this task starts. Native
            // movement already waits for mouse release and a confirmed layout.
            guard let bounds = self.menuBarVisibleBounds(on: preferredScreen) else {
                self.isActivatingNativeItem = false
                self.activationTask = nil
                self.hideNativeItems()
                self.reportActivationFailure("无法确定目标显示器的菜单栏可见区域")
                return
            }
            let reveal = await self.snapshotter.revealForClick(windowID: windowID, within: bounds, keepingCursorAtItem: !isTest)
            switch reveal {
            case .failed(let message):
                self.isActivatingNativeItem = false
                self.activationTask = nil
                self.hideNativeItems()
                self.reportActivationFailure(message)
                return
            case .ready(let placement):
                self.temporaryPlacement = placement
            }
#if MENU_BAR_INTEGRATION
            print("ACTIVATION revealed target=\(windowID) moved=\(self.temporaryPlacement != nil)")
#endif
            let needsImage = self.cachedSnapshots.first { $0.id == windowID }.map { $0.usesUnavailableImage || $0.usesApplicationIcon } ?? true
            if needsImage, let screen = preferredScreen,
               let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                _ = await self.snapshotter.cacheVisibleImages(displayID: number.uint32Value, bounds: bounds)
                self.refreshSnapshotCache()
            }
            if !isTest, let frame = self.snapshotter.windowFrame(for: windowID) {
                let tracker = MenuBarNativeMenuTracker(itemFrame: frame)
                self.nativeMenuTracker = tracker
                tracker.start { [weak self] in
                    guard let self, self.nativeContextMenuIsOpen else { return }
                    self.hideNativeItems()
                }
            }
            let didClick = await self.snapshotter.click(windowID: windowID, mouseButton: mouseButton,
                promptingForAccessibility: true, preserveCursorPosition: isTest, within: bounds)
            if didClick, !isTest { restoreCursor = false }
#if MENU_BAR_INTEGRATION
            print("ACTIVATION clicked=\(didClick)")
#endif
            self.isActivatingNativeItem = false
            self.activationTask = nil
            if !didClick {
                self.hideNativeItems()
                self.reportActivationFailure("原生点击事件未能送达，请检查辅助功能权限")
                return
            }
            // Leave ordinary native menus exposed until the next outside click or Escape.
            // A test item's own receipt is an observable completion signal instead.
            self.nativeContextMenuIsOpen = true
            self.startOutsideClickMonitor()
            if isTest {
                try? await Task.sleep(for: .milliseconds(250))
                if !self.receivedNativeTestClick {
                    self.reportActivationFailure("目标已移入可见区，事件已发送，但未收到原生点击回执")
                }
                self.hideNativeItems()
            }
        }
    }
}

#if MENU_BAR_INTEGRATION
// The disposable native integration executable exercises the real activation and
// dismissal code without startup image recovery or the app's saved preferences.
extension MenuBarController {
    func prepareForIntegrationVerification() {
        configureTrigger()
        configureDivider()
        dividerItem.length = 10_000
        state = .hidden
    }

    func activateForIntegrationVerification(_ windowID: CGWindowID) {
        startOutsideClickMonitor()
        activateNativeItem(windowID, mouseButton: .left)
    }

    var isNativeActivationIdleForVerification: Bool { !isActivatingNativeItem && restorationTask == nil }
    var dividerLengthForVerification: CGFloat { dividerItem.length }
}
#endif
