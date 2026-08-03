import AppKit

/// The deliberately small state machine behind the app: the divider hides native items while
/// the panel shows their captured appearance.
@MainActor
final class MenuBarController: NSObject {
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
    private lazy var contextMenu = makeContextMenu()
    private var cachedSnapshots: [StatusItemSnapshot] = []

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
        button.image = NSImage(systemSymbolName: "rectangle.3.group.fill", accessibilityDescription: "Show hidden menu bar items")
        button.image?.isTemplate = true
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
            contextMenu.popUp(positioning: nil, at: .zero, in: triggerItem.button)
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

        let hide = NSMenuItem(title: "按当前顺序隐藏图标", action: #selector(hideNativeItemsFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        return menu
    }

    @objc private func enterArrangementMode() {
        panel.close()
        state = .arranging
        dividerItem.length = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self else { return }
            self.refreshSnapshotCache(includeVisibleItems: true)
            self.panel.showArrangement(
                snapshots: self.cachedSnapshots,
                pinnedCount: 0,
                onChange: { [weak self] snapshots, visibleCount in
                    self?.applyArrangement(snapshots, visibleCount: visibleCount)
                },
                onClose: { [weak self] in self?.hideNativeItems() }
            )
        }
    }

    @objc private func hideNativeItemsFromMenu() {
        refreshSnapshotCache()
        hideNativeItems()
    }

    private func hideNativeItems() {
        panel.close()
        // Ice uses the same approach: a transparent, wide status item moves the items after it
        // out of the visible menu bar. Keep the control item to the divider's left in the status
        // bar; macOS remembers that position through autosaveName.
        dividerItem.button?.image = nil
        dividerItem.button?.isEnabled = false
        dividerItem.length = 10_000
        triggerItem.button?.toolTip = "显示隐藏的菜单栏图标（右键可调整）"
        state = .hidden
    }

    private func showPanel() {
        panel.show(
            snapshots: cachedSnapshots,
            onClose: { [weak self] in self?.hideNativeItems() },
            onActivate: { [weak self] windowID in self?.activateNativeItem(windowID) }
        )
        state = .shown
    }

    private func refreshSnapshotCache(includeVisibleItems: Bool = false) {
        let snapshots = snapshotter.capture(
            excluding: getpid(),
            excludingTitles: [ItemName.divider, ItemName.trigger],
            maximumX: includeVisibleItems ? nil : dividerItem.button?.window?.frame.maxX
        )
        if !snapshots.isEmpty {
            cachedSnapshots = snapshots
        }
    }

    private func applyArrangement(_ snapshots: [StatusItemSnapshot], visibleCount: Int) {
        guard let dividerID = dividerItem.button?.window?.windowNumber else { return }
        dividerItem.length = 1
        let visible = snapshots.prefix(visibleCount)
        let hidden = snapshots.dropFirst(visibleCount)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            for snapshot in visible.reversed() {
                _ = self.snapshotter.move(windowID: snapshot.id, nextTo: CGWindowID(dividerID), placingRight: true)
                try? await Task.sleep(for: .milliseconds(110))
            }
            for snapshot in hidden {
                _ = self.snapshotter.move(windowID: snapshot.id, nextTo: CGWindowID(dividerID), placingRight: false)
                try? await Task.sleep(for: .milliseconds(110))
            }
            try? await Task.sleep(for: .milliseconds(180))
            self.refreshSnapshotCache()
            self.hideNativeItems()
        }
    }

    private func activateNativeItem(_ windowID: CGWindowID) {
        // The original item must briefly return to the menu bar before macOS can deliver a click.
        dividerItem.length = 1
        state = .shown

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self else { return }
            _ = self.snapshotter.click(windowID: windowID, promptingForAccessibility: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                self?.hideNativeItems()
            }
        }
    }
}
