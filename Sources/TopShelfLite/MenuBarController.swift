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
        static let trigger = "TopShelfLite.Toggle.v3"
        static let divider = "TopShelfLite.Divider.v3"
    }

    private static let experimentalBuildLabel = "实验构建：原生就绪后点击 v8"

    private enum State {
        case hidden
        case shown
        case arranging
    }

    private let dividerItem: NSStatusItem
    private let triggerItem: NSStatusItem
    private let snapshotter = StatusItemSnapshotter()
    private let panel = HiddenItemsPanel()
    private var cachedSnapshots: [StatusItemSnapshot] = []
    private var outsideClickMonitor: Any?
    private var nativeContextMenuIsOpen = false
    private var layoutTask: Task<Void, Never>?
    private var isApplyingLayout = false
    private var iconChoice: IconChoice {
        get { IconChoice(rawValue: UserDefaults.standard.string(forKey: "TopShelfLite.IconChoice") ?? "") ?? .grid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "TopShelfLite.IconChoice") }
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
        configureTrigger()
        configureDivider()
        // Capture while native status items are still on-screen. Later taps can show this
        // cached representation directly, avoiding the distracting reveal-then-hide flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
            self?.refreshSnapshotCache()
            self?.hideNativeItems()
        }
    }

    func stop() {
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
        let buildLabel = NSMenuItem(title: Self.experimentalBuildLabel, action: nil, keyEquivalent: "")
        buildLabel.isEnabled = false
        menu.addItem(buildLabel)
        menu.addItem(.separator())
        let arrange = NSMenuItem(
            title: "编辑所有菜单栏图标（实验）",
            action: #selector(enterArrangementMode),
            keyEquivalent: ""
        )
        arrange.target = self
        menu.addItem(arrange)

        let refresh = NSMenuItem(
            title: "刷新隐藏图标",
            action: #selector(refreshHiddenItems),
            keyEquivalent: ""
        )
        refresh.target = self
        menu.addItem(refresh)

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
            title: "开机时启动 TopShelfLite",
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

        let systemSettings = NSMenuItem(title: "打开系统设置：控制中心", action: #selector(openMenuBarSettings), keyEquivalent: "")
        systemSettings.target = self
        menu.addItem(systemSettings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 TopShelfLite", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func enterArrangementMode() {
        guard !isApplyingLayout else { return }
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

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func openMenuBarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshHiddenItems() {
        if state == .arranging {
            // The divider is already narrow, so the native item frames are current.
            refreshSnapshotCache()
            return
        }

        // The wide hiding divider can make the WindowServer report no usable hidden frames.
        // Restore the native layout first, wait for it to settle, then capture a new cache.
        // Keeping the old cache on an empty scan avoids erasing usable snapshots on a transient
        // WindowServer miss.
        dividerItem.length = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
            guard let self else { return }
            self.refreshSnapshotCache()
            self.hideNativeItems()
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

    private func showPanel() {
        panel.show(
            snapshots: cachedSnapshots,
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
        )
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
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch self.state {
                case .shown:
                    if self.nativeContextMenuIsOpen {
                        self.nativeContextMenuIsOpen = false
                        self.hideNativeItems()
                    } else {
                        self.panel.close()
                    }
                case .arranging where self.isNativeMenuBarClick():
                    self.hideNativeItems()
                case .hidden, .arranging:
                    break
                }
            }
        }
    }

    private func isNativeMenuBarClick() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        return point.y >= screen.frame.maxY - NSStatusBar.system.thickness
    }

    private func stopOutsideClickMonitor() {
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

    private func refreshSnapshotCache() {
        let snapshots = snapshotter.capture(
            excluding: getpid(),
            excludingTitles: [ItemName.divider, ItemName.trigger],
            maximumX: dividerItem.button?.window?.frame.maxX
        )
        if !snapshots.isEmpty {
            cachedSnapshots = snapshots
        }
    }

    private func activateNativeItem(_ windowID: CGWindowID, mouseButton: CGMouseButton) {
        // The original item must briefly return to the menu bar before macOS can deliver a click.
        dividerItem.length = 1
        state = .shown

        Task { @MainActor [weak self] in
            guard let self else { return }
            // A WindowServer frame can move before the status-item host finishes installing its
            // contextual-menu tracking. A short settle time is more reliable for right clicks.
            try? await Task.sleep(for: .milliseconds(220))

            let didClick = await self.snapshotter.click(
                windowID: windowID,
                mouseButton: mouseButton,
                promptingForAccessibility: true
            )
            if mouseButton == .right, didClick {
                // Keep the real item exposed while its own contextual menu is on screen.
                self.nativeContextMenuIsOpen = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    self?.hideNativeItems()
                }
            }
        }
    }
}
