import AppKit

/// A direct-manipulation editor. Drag an icon to the left of the blue divider to pin it, or to
/// the right to keep it in the expandable shelf.
final class ArrangementEditorView: NSView {
    private var snapshots: [StatusItemSnapshot]
    private var pinnedCount: Int
    private let itemWidth: CGFloat = 34
    private let edge: CGFloat = 8
    private var draggedIndex: Int?
    private let onChange: ([StatusItemSnapshot], Int) -> Void

    init(snapshots: [StatusItemSnapshot], pinnedCount: Int, onChange: @escaping ([StatusItemSnapshot], Int) -> Void) {
        self.snapshots = snapshots
        self.pinnedCount = min(max(pinnedCount, 0), snapshots.count)
        self.onChange = onChange
        super.init(frame: CGRect(x: 0, y: 0, width: max(160, edge * 2 + CGFloat(snapshots.count) * itemWidth + 4), height: 40))
        toolTip = "直接拖动图标：蓝线左侧置顶，右侧隐藏"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { frame.size }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for (index, snapshot) in snapshots.enumerated() {
            let rect = CGRect(x: edge + CGFloat(index) * itemWidth, y: 5, width: itemWidth, height: 30)
            snapshot.image.draw(in: rect.insetBy(dx: 3, dy: 2), from: .zero, operation: .sourceOver,
                                fraction: index < pinnedCount ? 1 : 0.55)
        }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: CGRect(x: markerX, y: 5, width: 4, height: 30), xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let index = Int((convert(event.locationInWindow, from: nil).x - edge) / itemWidth)
        guard snapshots.indices.contains(index) else { return }
        draggedIndex = index
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let source = draggedIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        let wasPinned = source < pinnedCount
        let item = snapshots.remove(at: source)
        if wasPinned { pinnedCount -= 1 }
        let wantsPinned = point.x < markerX
        let rawIndex = min(max(Int(((point.x - edge) / itemWidth).rounded()), 0), snapshots.count)
        let destination: Int
        if wantsPinned {
            destination = min(rawIndex, pinnedCount)
            pinnedCount += 1
        } else {
            destination = max(rawIndex, pinnedCount)
        }
        snapshots.insert(item, at: min(destination, snapshots.count))
        draggedIndex = min(destination, snapshots.count - 1)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard draggedIndex != nil else { return }
        draggedIndex = nil
        NSCursor.pop()
        onChange(snapshots, pinnedCount)
    }

    private var markerX: CGFloat { edge + CGFloat(pinnedCount) * itemWidth }
}
