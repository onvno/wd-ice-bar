import AppKit

/// A proxy-only editor for every tracked app item. The blue marker is the boundary: items to its
/// left are intended to remain visible in macOS; items to its right belong in the hidden shelf.
final class ArrangementEditorView: NSView {
    private var snapshots: [StatusItemSnapshot]
    private var visibleCount: Int
    private var draggedIndex: Int?
    private var isCommitLocked = false
    private let itemWidth: CGFloat = 36
    private let edge: CGFloat = 10
    private let onRemove: (StatusItemSnapshot) -> Void
    private let onCommit: ([StatusItemSnapshot], Int) -> Void

    init(snapshots: [StatusItemSnapshot], visibleCount: Int, onRemove: @escaping (StatusItemSnapshot) -> Void, onCommit: @escaping ([StatusItemSnapshot], Int) -> Void) {
        self.snapshots = snapshots
        self.visibleCount = min(max(visibleCount, 0), snapshots.count)
        self.onRemove = onRemove
        self.onCommit = onCommit
        let width = max(260, edge * 2 + CGFloat(snapshots.count) * itemWidth + 6)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 44))
        toolTip = "拖动图标；蓝线左侧显示在原生菜单栏，右侧隐藏在 wd-ice-bar；右键图标可从虚拟菜单移除"
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { frame.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setCommitLocked(_ locked: Bool) {
        isCommitLocked = locked
        toolTip = locked
            ? "正在应用到原生菜单栏…"
            : "拖动图标；蓝线左侧显示在原生菜单栏，右侧隐藏在 wd-ice-bar；右键图标可从虚拟菜单移除"
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, snapshot) in snapshots.enumerated() {
            let rect = CGRect(x: edge + CGFloat(index) * itemWidth, y: 6, width: itemWidth, height: 30)
            snapshot.image.draw(
                in: rect.insetBy(dx: 4, dy: 3),
                from: .zero,
                operation: .sourceOver,
                fraction: index < visibleCount ? 1 : 0.58
            )
        }

        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: CGRect(x: markerX, y: 5, width: 3, height: 32), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isCommitLocked, draggedIndex == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= edge, point.y >= 6, point.y <= 36 else { return }
        let index = Int((point.x - edge) / itemWidth)
        guard snapshots.indices.contains(index) else { return }
        let snapshot = snapshots[index]
        let menu = NSMenu()
        let label = NSMenuItem(title: snapshot.label, action: nil, keyEquivalent: "")
        menu.addItem(label)
        menu.addItem(SnapshotMenuAction(title: "从虚拟菜单移除") { [weak self] in
            self?.onRemove(snapshot)
        })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isCommitLocked else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.x - edge) / itemWidth)
        guard snapshots.indices.contains(index) else { return }
        draggedIndex = index
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isCommitLocked else { return }
        guard let source = draggedIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        let wasVisible = source < visibleCount
        let item = snapshots.remove(at: source)
        if wasVisible { visibleCount -= 1 }

        let wantsVisible = point.x < markerX
        let rawIndex = min(max(Int(((point.x - edge) / itemWidth).rounded()), 0), snapshots.count)
        let destination: Int
        if wantsVisible {
            destination = min(rawIndex, visibleCount)
            visibleCount += 1
        } else {
            destination = max(rawIndex, visibleCount)
        }

        snapshots.insert(item, at: min(destination, snapshots.count))
        draggedIndex = min(destination, snapshots.count - 1)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isCommitLocked else { return }
        guard draggedIndex != nil else { return }
        draggedIndex = nil
        NSCursor.pop()
        onCommit(snapshots, visibleCount)
    }

    private var markerX: CGFloat { edge + CGFloat(visibleCount) * itemWidth }
}
