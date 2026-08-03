import AppKit

/// Edits only TopShelfLite's cached hidden items. It deliberately never reads the right-side
/// system group (clock, Control Center, battery, and so on).
final class ArrangementEditorView: NSView {
    private let snapshots: [StatusItemSnapshot]
    private let itemWidth: CGFloat = 30
    private let edgeInset: CGFloat = 7
    private let markerWidth: CGFloat = 4
    private var pinnedCount: Int
    private var isDraggingMarker = false
    private let onChange: (Int) -> Void

    init(snapshots: [StatusItemSnapshot], pinnedCount: Int, onChange: @escaping (Int) -> Void) {
        self.snapshots = snapshots
        self.pinnedCount = min(max(pinnedCount, 0), snapshots.count)
        self.onChange = onChange
        let width = edgeInset * 2 + CGFloat(snapshots.count) * itemWidth + markerWidth
        super.init(frame: CGRect(x: 0, y: 0, width: max(width, 120), height: 28))
        toolTip = "按住 ⌘ 拖动蓝色分隔标记：左侧置顶，右侧隐藏"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { frame.size }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for (index, snapshot) in snapshots.enumerated() {
            let rect = CGRect(x: edgeInset + CGFloat(index) * itemWidth, y: 4, width: itemWidth, height: 20)
            snapshot.image.draw(
                in: rect.insetBy(dx: 4, dy: 1),
                from: .zero,
                operation: .sourceOver,
                fraction: index < pinnedCount ? 1 : 0.48
            )
        }

        NSColor.systemBlue.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: markerX, y: 3, width: markerWidth, height: 22),
            xRadius: 2,
            yRadius: 2
        ).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.modifierFlags.contains(.command), abs(point.x - markerX - markerWidth / 2) < 12 else {
            NSSound.beep()
            return
        }
        isDraggingMarker = true
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingMarker else { return }
        let point = convert(event.locationInWindow, from: nil)
        let nextCount = min(max(Int(((point.x - edgeInset) / itemWidth).rounded()), 0), snapshots.count)
        guard nextCount != pinnedCount else { return }
        pinnedCount = nextCount
        needsDisplay = true
        onChange(nextCount)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingMarker else { return }
        isDraggingMarker = false
        NSCursor.pop()
    }

    private var markerX: CGFloat {
        edgeInset + CGFloat(pinnedCount) * itemWidth
    }
}
