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
    private var temporaryActivationTask: Task<Void, Never>?
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
        temporaryActivationTask?.cancel()
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
            title: "调整顶部图标（按住 ⌘ 拖动）",
            action: #selector(enterArrangementMode),
            keyEquivalent: ""
        )
        arrange.target = self
        menu.addItem(arrange)

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
        panel.close()
        // A visible, narrow divider gives the user a stable landmark. While this mode is on,
        // macOS's standard ⌘-drag can move a status item to either side of it.
        dividerItem.length = 16
        dividerItem.button?.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Hidden item boundary")
        dividerItem.button?.image?.isTemplate = true
        dividerItem.button?.isEnabled = true
        triggerItem.button?.toolTip = "调整中：按住 ⌘ 拖动图标；点击后按当前顺序隐藏"
        state = .arranging
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func openMenuBarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
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
        temporaryActivationTask?.cancel()
        temporaryActivationTask = nil
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
            onActivate: { [weak self] windowID in self?.activateNativeItem(windowID) }
        )
        state = .shown
        updateTriggerIcon(isHidden: false)
        startOutsideClickMonitor()
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state == .shown else { return }
                self.panel.close()
            }
        }
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

    private func activateNativeItem(_ windowID: CGWindowID) {
        // Do not expand the complete hidden section. Move only the selected real item across
        // the divider, click it in-place, then move it back after its native interface closes.
        guard let dividerWindowID = snapshotter.statusItemWindowID(titled: ItemName.divider) else {
            hideNativeItems()
            return
        }

        temporaryActivationTask?.cancel()
        state = .shown

        temporaryActivationTask = Task { [weak self, snapshotter] in
            guard let self else { return }
            guard let context = await snapshotter.temporarilyShowAndClick(
                windowID: windowID,
                toRightOf: dividerWindowID,
                promptingForAccessibility: true
            ) else {
                guard !Task.isCancelled else { return }
                self.hideNativeItems()
                return
            }

            await snapshotter.waitForTemporaryInterfaceToClose(context)
            guard !Task.isCancelled else { return }
            // A 10,000pt divider places its left edge outside the display. Shrink it only
            // while returning this one item so macOS receives a valid ⌘-drag destination.
            dividerItem.length = 16
            _ = await snapshotter.rehideTemporaryItem(context)
            guard !Task.isCancelled else { return }
            self.hideNativeItems()
        }
    }
}
