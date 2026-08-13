import AppKit

final class HiddenItemsPanel: NSPanel {
    private var closeHandler: (() -> Void)?
    private var activateHandler: ((StatusItemSnapshot, CGMouseButton) -> Void)?
    private weak var arrangementEditor: ArrangementEditorView?
    private var isDismissing = false

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .mainMenu + 1
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
    }

    func show(
        snapshots: [StatusItemSnapshot],
        onClose: @escaping () -> Void,
        onActivate: @escaping (StatusItemSnapshot, CGMouseButton) -> Void
    ) {
        closeHandler = onClose
        activateHandler = onActivate
        contentView = makeContent(snapshots: snapshots)
        positionAtRightEdge()
        alphaValue = 0
        orderFrontRegardless()
        animateAlpha(to: 1)
    }

    func showArrangement(
        snapshots: [StatusItemSnapshot],
        visibleCount: Int,
        onCommit: @escaping ([StatusItemSnapshot], Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        closeHandler = onClose
        activateHandler = nil

        let effect = makeEffectView()
        let editor = ArrangementEditorView(snapshots: snapshots, visibleCount: visibleCount, onCommit: onCommit)
        arrangementEditor = editor
        editor.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            editor.topAnchor.constraint(equalTo: effect.topAnchor),
            editor.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        positionAtRightEdge()
        alphaValue = 0
        orderFrontRegardless()
        animateAlpha(to: 1)
    }

    /// Removes an editor immediately without invoking its close action. Used while a layout
    /// transaction is in progress; invoking that action would re-hide the native items too soon.
    func dismissForLayoutTransaction() {
        closeHandler = nil
        activateHandler = nil
        arrangementEditor = nil
        orderOut(nil)
        alphaValue = 1
    }

    func setArrangementCommitLocked(_ locked: Bool) {
        arrangementEditor?.setCommitLocked(locked)
    }

    override func close() {
        guard !isDismissing else { return }
        let handler = closeHandler
        closeHandler = nil
        activateHandler = nil
        arrangementEditor = nil
        guard isVisible else {
            handler?()
            return
        }
        isDismissing = true
        animateAlpha(to: 0) { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            self.isDismissing = false
            handler?()
        }
    }

    private func makeContent(snapshots: [StatusItemSnapshot]) -> NSView {
        let effect = makeEffectView()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        if snapshots.isEmpty {
            let label = NSTextField(labelWithString: "未捕捉到隐藏图标。")
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(label)

            let permissionButton = NSButton(title: "允许屏幕录制", target: self, action: #selector(requestScreenRecording))
            permissionButton.bezelStyle = .inline
            stack.addArrangedSubview(permissionButton)
        } else {
            for snapshot in snapshots {
                let button = SnapshotButton(image: snapshot.image, target: self, action: #selector(activateSnapshot))
                button.imageScaling = .scaleProportionallyDown
                button.setFrameSize(CGSize(width: max(20, snapshot.image.size.width), height: 24))
                button.toolTip = snapshot.isOffscreen
                    ? "\(snapshot.label)；当前在屏幕外，请先通过“调整菜单显隐”移到显示侧"
                    : snapshot.label
                button.bezelStyle = .regularSquare
                button.isBordered = false
                // These are captured pixels, not template symbols. Preserve their original
                // color and give both black and white status icons enough local contrast.
                button.image?.isTemplate = false
                button.contentTintColor = nil
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
                button.layer?.cornerRadius = 6
                button.snapshot = snapshot
                button.rightMouseUpHandler = { [weak self, weak button] in
                    guard let self, let button else { return }
                    self.forwardSnapshotActivation(button, mouseButton: .right)
                }
                stack.addArrangedSubview(button)
            }
        }
        return effect
    }

    @objc private func activateSnapshot(_ sender: SnapshotButton) {
        forwardSnapshotActivation(sender, mouseButton: .left)
    }

    private func forwardSnapshotActivation(_ sender: SnapshotButton, mouseButton: CGMouseButton) {
        guard let snapshot = sender.snapshot else { return }
        let handler = activateHandler
        closeHandler = nil
        activateHandler = nil
        super.close()
        handler?(snapshot, mouseButton)
    }

    @objc private func requestScreenRecording() {
        ScreenCapturePermission.request()
        close()
    }

    private func makeEffectView() -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        effect.layer?.borderWidth = 1
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        return effect
    }

    private func positionAtRightEdge() {
        guard let screen = NSScreen.main, let contentView else { return }
        let size = contentView.fittingSize
        let menuBarHeight = NSStatusBar.system.thickness
        let origin = CGPoint(
            x: max(screen.visibleFrame.minX + 8, screen.visibleFrame.maxX - size.width - 8),
            y: screen.frame.maxY - menuBarHeight - size.height - 8
        )
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func animateAlpha(to value: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            animator().alphaValue = value
        } completionHandler: {
            completion?()
        }
    }
}

/// NSButton's default action routing is optimized for primary clicks. Capture secondary clicks
/// directly so a nonactivating panel cannot swallow them before they reach the forwarding logic.
private final class SnapshotButton: NSButton {
    var snapshot: StatusItemSnapshot?
    var rightMouseUpHandler: (() -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Intentionally consume the down event: the original status item's own context menu is
        // opened only after wd-ice-bar has restored that native item.
    }

    override func rightMouseUp(with event: NSEvent) {
        rightMouseUpHandler?()
    }
}
