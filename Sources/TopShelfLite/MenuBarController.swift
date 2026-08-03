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
    private var pinnedCount: Int
    private var pinnedStack: NSStackView?

    // New namespace: do not reuse the experimental all-status-item selection, which could
    // include macOS-owned entries such as the clock and Control Center.
    private static let pinnedCountKey = "TopShelfLite.HiddenCachePinnedItemCount.v1"

    private var state: State = .shown

    override init() {
        // Mirror Ice's first-run placement: position 0 remains visible as the toggle, while
        // position 1 is the transparent divider immediately to its left.
        let defaults = UserDefaults.standard
        let triggerKey = "NSStatusItem Preferred Position \(ItemName.trigger)"
        let dividerKey = "NSStatusItem Preferred Position \(ItemName.divider)"
        if defaults.object(forKey: triggerKey) == nil { defaults.set(0, forKey: triggerKey) }
        if defaults.object(forKey: dividerKey) == nil { defaults.set(1, forKey: dividerKey) }
        pinnedCount = defaults.object(forKey: Self.pinnedCountKey) == nil
            ? 0
            : defaults.integer(forKey: Self.pinnedCountKey)

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
        renderPinnedBar()
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
            hideNativeItems()
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let arrange = NSMenuItem(
            title: "调整顶部 / 隐藏图标（⌘ 拖动分隔标记）",
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
        guard !cachedSnapshots.isEmpty else {
            showPanel()
            return
        }
        panel.showArrangement(
            snapshots: cachedSnapshots,
            pinnedCount: pinnedCount,
            onPinnedCountChange: { [weak self] count in self?.setPinnedCount(count) },
            onClose: { [weak self] in self?.hideNativeItems() }
        )
        triggerItem.button?.toolTip = "调整中：按住 ⌘ 拖动蓝色分隔标记"
        state = .arranging
    }

    @objc private func hideNativeItemsFromMenu() {
        hideNativeItems()
    }

    private func hideNativeItems() {
        panel.close()
        // Ice uses the same approach: a transparent, wide status item moves the items after it
        // out of the visible menu bar. Keep the control item to the divider's left in the status
        // bar; macOS remembers that position through autosaveName.
        dividerItem.length = 10_000
        renderPinnedBar()
        triggerItem.button?.toolTip = "显示隐藏图标（右键可调整顶部 / 隐藏图标）"
        state = .hidden
    }

    private func showPanel() {
        panel.show(
            snapshots: Array(cachedSnapshots.dropFirst(pinnedCount)),
            onClose: { [weak self] in self?.hideNativeItems() },
            onActivate: { [weak self] windowID in self?.activateNativeItem(windowID) }
        )
        state = .shown
    }

    private func refreshSnapshotCache() {
        let snapshots = snapshotter.capture(
            excluding: getpid(),
            excludingTitles: [ItemName.divider, ItemName.trigger],
            maximumX: dividerItem.button?.window?.frame.maxX
        )
        if !snapshots.isEmpty {
            cachedSnapshots = snapshots
            pinnedCount = min(pinnedCount, snapshots.count)
            renderPinnedBar()
        }
    }

    private func setPinnedCount(_ count: Int) {
        pinnedCount = min(max(count, 0), cachedSnapshots.count)
        UserDefaults.standard.set(pinnedCount, forKey: Self.pinnedCountKey)
        renderPinnedBar()
    }

    private func renderPinnedBar() {
        guard let hostButton = triggerItem.button else { return }
        pinnedStack?.removeFromSuperview()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        for snapshot in cachedSnapshots.prefix(pinnedCount) {
            let button = NSButton(image: snapshot.image, target: self, action: #selector(activatePinnedItem))
            button.imageScaling = .scaleProportionallyDown
            button.setFrameSize(CGSize(width: 24, height: 20))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.contentTintColor = .white
            button.toolTip = snapshot.label
            button.identifier = NSUserInterfaceItemIdentifier(String(snapshot.id))
            stack.addArrangedSubview(button)
        }

        let toggleButton = NSButton(
            image: NSImage(systemSymbolName: "rectangle.3.group.fill", accessibilityDescription: "Show hidden menu bar items")!,
            target: self,
            action: #selector(toggle)
        )
        toggleButton.imageScaling = .scaleProportionallyDown
        toggleButton.setFrameSize(CGSize(width: 24, height: 20))
        toggleButton.bezelStyle = .regularSquare
        toggleButton.isBordered = false
        toggleButton.toolTip = "显示隐藏图标；右键调整"
        toggleButton.sendAction(on: [.leftMouseUp, .rightMouseUp])
        stack.addArrangedSubview(toggleButton)

        hostButton.image = nil
        hostButton.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: hostButton.leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: hostButton.trailingAnchor, constant: -3),
            stack.centerYAnchor.constraint(equalTo: hostButton.centerYAnchor),
        ])
        pinnedStack = stack
        triggerItem.length = CGFloat(max(1, pinnedCount) * 25 + 30)
    }

    @objc private func activatePinnedItem(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UInt32(value) else { return }
        activateNativeItem(id)
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
