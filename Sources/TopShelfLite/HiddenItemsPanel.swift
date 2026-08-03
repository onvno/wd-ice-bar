import AppKit

final class HiddenItemsPanel: NSPanel {
    private var closeHandler: (() -> Void)?
    private var activateHandler: ((CGWindowID) -> Void)?

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
        onActivate: @escaping (CGWindowID) -> Void
    ) {
        closeHandler = onClose
        activateHandler = onActivate
        contentView = makeContent(snapshots: snapshots)
        positionAtRightEdge()
        orderFrontRegardless()
    }

    func showArrangement(
        snapshots: [StatusItemSnapshot],
        pinnedCount: Int,
        onChange: @escaping ([StatusItemSnapshot], Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        closeHandler = onClose
        activateHandler = nil
        let effect = makeEffectView()
        effect.layer?.cornerRadius = 10
        let editor = ArrangementEditorView(snapshots: snapshots, pinnedCount: pinnedCount, onChange: onChange)
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
        orderFrontRegardless()
    }

    override func close() {
        let handler = closeHandler
        closeHandler = nil
        activateHandler = nil
        super.close()
        handler?()
    }

    private func makeContent(snapshots: [StatusItemSnapshot]) -> NSView {
        let effect = makeEffectView()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
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
                let button = NSButton(image: snapshot.image, target: self, action: #selector(activateSnapshot))
                button.imageScaling = .scaleProportionallyDown
                button.setFrameSize(CGSize(width: max(20, snapshot.image.size.width), height: 24))
                button.toolTip = snapshot.label
                button.bezelStyle = .regularSquare
                button.isBordered = false
                button.contentTintColor = .white
                button.identifier = NSUserInterfaceItemIdentifier(String(snapshot.id))
                stack.addArrangedSubview(button)
            }
        }
        return effect
    }

    @objc private func activateSnapshot(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue, let id = UInt32(identifier) else { return }
        let handler = activateHandler
        closeHandler = nil
        activateHandler = nil
        super.close()
        handler?(id)
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
            y: screen.frame.maxY - menuBarHeight - size.height - 4
        )
        setFrame(CGRect(origin: origin, size: size), display: true)
    }
}
