import AppKit

/// Explicit, disposable test items. Native button actions record a receipt; proxy
/// clicks never increment the counter directly, so a failed forwarding path is visible.
@MainActor
final class MenuBarOverflowTest: NSObject, NSWindowDelegate {
    private var items: [(name: String, item: NSStatusItem, image: NSImage)] = []
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var measurementLabel: NSTextField?
    private var clicks = 0
    private let session = UUID().uuidString
    var insertionPosition: (() -> Int)?
    var shortcutAvailable = false
    var onNativeReceipt: (() -> Void)?
    var onShowVirtualMenu: (() -> Void)?
    var onMeasure: (() -> String)?
    var onChange: (([String: NSImage]) -> Void)?

    var isActive: Bool { !items.isEmpty }

    func show() {
        if let window {
            present(window)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 330),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "菜单栏溢出验证"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        self.window = window
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let instructions = NSTextField(wrappingLabelWithString:
            "逐步添加 T01、T02…真实菜单项，让菜单栏变满。\n点击“打开虚拟菜单”，检查屏幕外测试项是否出现。\n点击图标后，下面有对应编号回执才表示原生点击成功。")
        stack.addArrangedSubview(instructions)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for (title, action) in [("添加 5 个", #selector(addFive)), ("添加 10 个", #selector(addTen)),
                                ("打开虚拟菜单", #selector(showVirtual)), ("清理全部", #selector(clearAll))] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons)
        let label = NSTextField(wrappingLabelWithString: "尚未添加测试项。")
        stack.addArrangedSubview(label)
        statusLabel = label
        let measurement = NSTextField(wrappingLabelWithString: "窗口识别数量会在添加测试项后更新。")
        stack.addArrangedSubview(measurement)
        measurementLabel = measurement
        let shortcut = shortcutAvailable ? "快捷键 ⌃⌥⌘I 可重新打开本窗口。" : "快捷键未注册成功，可重新打开 app 找回本窗口。"
        let hint = NSTextField(wrappingLabelWithString: "关闭本窗口会清理全部测试项。\(shortcut)\n顶部图标不可见时，也可在 Finder 中重新打开 wd-ice-bar.app。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(NSButton(title: "清理并退出 wd-ice-bar", target: self, action: #selector(quitApp)))
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
            ])
        }
        present(window)
    }

    private func present(_ window: NSWindow) {
        // Put the recovery window on the display where the user is working, even
        // if AppKit's main screen is still an external display from an earlier click.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                          y: screen.visibleFrame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        clear()
        NSApp.terminate(nil)
    }

    @objc private func addFive() { add(5) }
    @objc private func addTen() { add(10) }
    @objc private func showVirtual() {
        onShowVirtualMenu?()
        measurementLabel?.stringValue = onMeasure?() ?? ""
    }
    @objc private func clearAll() { clear() }

    private func add(_ count: Int) {
        let firstPosition = max(1, insertionPosition?() ?? 1)
        for _ in 0..<count where items.count < 60 {
            let number = items.count + 1
            let name = "WDIceBar.Test.\(session).\(number)"
            // Position 0 competes with the app's control. Insert immediately to
            // its left instead; the independent window remains the recovery path.
            UserDefaults.standard.set(firstPosition + number - 1,
                                      forKey: "NSStatusItem Preferred Position \(name)")
            let item = NSStatusBar.system.statusItem(withLength: 80)
            item.autosaveName = name
            let text = String(format: "T%02d", number)
            let image = NSImage(size: NSSize(width: 30, height: 24), flipped: false) { rect in
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white,
                ]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: CGPoint(x: (rect.width - size.width) / 2,
                                                    y: (rect.height - size.height) / 2), withAttributes: attributes)
                return true
            }
            image.isTemplate = false
            item.button?.image = image
            item.button?.toolTip = "溢出验证 \(text)"
            item.button?.tag = number
            item.button?.target = self
            item.button?.action = #selector(receiveNativeClick(_:))
            items.append((name, item, image))
        }
        publish()
        statusLabel?.stringValue = "已创建 \(items.count) 个测试项；累计原生点击回执 \(clicks) 次。"
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) { [weak self] in
            guard let self else { return }
            self.measurementLabel?.stringValue = self.onMeasure?() ?? ""
        }
    }

    @objc private func receiveNativeClick(_ sender: NSStatusBarButton) {
        clicks += 1
        onNativeReceipt?()
        statusLabel?.stringValue = String(format: "收到 T%02d 的原生点击；累计回执 %d 次。", sender.tag, clicks)
    }

    func reportFailure(_ message: String) {
        statusLabel?.stringValue = "点击未完成：\(message)"
    }

    func clear() {
        for entry in items {
            NSStatusBar.system.removeStatusItem(entry.item)
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(entry.name)")
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible \(entry.name)")
        }
        items.removeAll()
        clicks = 0
        statusLabel?.stringValue = "测试项已全部清理。"
        measurementLabel?.stringValue = ""
        publish()
    }

    private func publish() {
        onChange?(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.image) }))
    }

    func windowWillClose(_ notification: Notification) { clear() }
}
