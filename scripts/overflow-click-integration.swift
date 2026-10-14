// Disposable real-menu-bar integration test. Run with verify-menu-bar-overflow.sh.
import AppKit
import ApplicationServices

@MainActor
final class Receipt: NSObject, NSMenuDelegate {
    var count = 0
    var menuOpens = 0
    var menuCloses = 0
    func menuWillOpen(_ menu: NSMenu) { menuOpens += 1 }
    func menuDidClose(_ menu: NSMenu) { menuCloses += 1 }
    @objc func clicked(_ sender: NSStatusBarButton) { count += 1 }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let receipt = Receipt()
let controllerMode = CommandLine.arguments.contains("--controller")
let menuMode = controllerMode || CommandLine.arguments.contains("--native-menu")
if controllerMode {
    UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position WDClickIntegration.Toggle")
    UserDefaults.standard.set(1, forKey: "NSStatusItem Preferred Position WDClickIntegration.Divider")
}
let controller: MenuBarController? = controllerMode ? MenuBarController() : nil
controller?.prepareForIntegrationVerification()
let nativeMenu = NSMenu()
nativeMenu.delegate = receipt
nativeMenu.addItem(NSMenuItem(title: "原生菜单保持打开验证", action: nil, keyEquivalent: ""))
var cursorRestoreErrors: [CGFloat] = []
MenuBarCursorGuard.verificationHook = { cursorRestoreErrors.append($0) }
let snapshotter = StatusItemSnapshotter()
let ownTitles: Set<String> = ["WDIceBar.Toggle.v1", "WDIceBar.Divider.v1", "WDClickIntegration.Toggle", "WDClickIntegration.Divider"]
let baseline = Set(snapshotter.captureAllCandidates(excluding: getpid(), excludingTitles: ownTitles).map(\.id))
var fixtures: [(String, NSStatusItem)] = []
@MainActor func cleanup() {
    for (name, item) in fixtures {
        NSStatusBar.system.removeStatusItem(item)
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
    }
    fixtures.removeAll()
    controller?.stop()
    if controllerMode {
        for name in ["WDClickIntegration.Toggle", "WDClickIntegration.Divider"] {
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
        }
    }
}
for number in 1...24 {
    let name = "WDClickIntegration.\(number)"
    UserDefaults.standard.set(number - 1 + (controllerMode ? 2 : 0), forKey: "NSStatusItem Preferred Position \(name)")
    let item = NSStatusBar.system.statusItem(withLength: 80)
    item.autosaveName = name
    item.button?.title = "I\(number)"
    item.button?.target = receipt
    item.button?.action = #selector(Receipt.clicked(_:))
    if menuMode, number == 24 { item.menu = nativeMenu }
    fixtures.append((name, item))
    snapshotter.testItemImages[name] = NSImage(size: NSSize(width: 24, height: 24))
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    Task { @MainActor in
        defer { cleanup(); app.terminate(nil) }
        let after = Set(snapshotter.captureAllCandidates(excluding: getpid(), excludingTitles: ownTitles).map(\.id))
        print("PRESERVATION baseline=\(baseline.count) missingAfterFill=\(baseline.subtracting(after).count)")
        guard AXIsProcessTrusted() else { print("CLICK_BLOCKED: test process lacks Accessibility permission"); return }
        guard let screen = NSScreen.screens.first,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let target = snapshotter.statusItemWindowID(titled: "WDClickIntegration.24") else {
            print("CLICK_BLOCKED: no target"); return
        }
        let display = CGDisplayBounds(id.uint32Value)
        let area = screen.auxiliaryTopRightArea
        let bounds = CGRect(x: area?.minX ?? display.minX, y: display.minY,
                            width: area?.width ?? display.width, height: display.height)
        // Wait briefly for real input to settle; each gesture still respects new
        // real movement and reports its restore error independently of this wait.
        let quietDeadline = ContinuousClock.now + .seconds(3)
        while CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved) < 0.3, ContinuousClock.now < quietDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let cursorBefore = CGEvent(source: nil)?.location
        let hardwareBefore = CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved)
        if let controller {
            let divider = snapshotter.statusItemWindowID(titled: "WDClickIntegration.Divider")
            print("SETUP divider=\(divider.map(String.init) ?? "nil") targetX=\(snapshotter.windowFrame(for: target)?.minX ?? -99999) dividerX=\(divider.flatMap { snapshotter.windowFrame(for: $0)?.minX } ?? -99999)")
            let siblings = (1...23).compactMap { snapshotter.statusItemWindowID(titled: "WDClickIntegration.\($0)") }
            let originallyHidden = siblings.filter { sibling in divider.flatMap { snapshotter.isWindow(sibling, toRightOf: $0) } == false }
            controller.activateForIntegrationVerification(target)
            let deadline = ContinuousClock.now + .seconds(10)
            repeat { try? await Task.sleep(for: .milliseconds(100)) }
            while !controller.isNativeActivationIdleForVerification && ContinuousClock.now < deadline
            try? await Task.sleep(for: .milliseconds(2200))
            let exposedSiblings = originallyHidden.filter { sibling in divider.flatMap { snapshotter.isWindow(sibling, toRightOf: $0) } != false }
            print("CONTROLLER hiddenSiblings=\(originallyHidden.count) unexpectedlyExposed=\(exposedSiblings.count) dividerLength=\(controller.dividerLengthForVerification)")
            print("NATIVE_MENU opens=\(receipt.menuOpens) closesBeforeDismiss=\(receipt.menuCloses)")
            // Inject Escape as a real-user event (source PID 0). This exercises
            // the production dismissal monitors, not a direct call to hide().
            let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
            escape.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            escape.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(1500))
            let restoredHidden = divider.flatMap { snapshotter.isWindow(target, toRightOf: $0) } == false
            let success = receipt.menuOpens == 1 && receipt.menuCloses == 1 && exposedSiblings.isEmpty
                && originallyHidden.count == 23 && controller.dividerLengthForVerification == 10_000 && restoredHidden
            print("CONTROLLER_RESULT menuCloses=\(receipt.menuCloses) targetHiddenAgain=\(restoredHidden) passed=\(success)")
            if !success { cleanup(); exit(1) }
            return
        }
        switch await snapshotter.revealForClick(windowID: target, within: bounds) {
        case .failed(let reason): print("REVEAL_FAILED: \(reason) hardwareMoves=\(CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved) &- hardwareBefore)")
        case .ready(let placement):
            try? await Task.sleep(for: .milliseconds(100))
            let capturedCount = await snapshotter.cacheVisibleImages(displayID: id.uint32Value, bounds: bounds)
            snapshotter.testItemImages.removeValue(forKey: "WDClickIntegration.24")
            let actualImage = snapshotter.captureAllCandidates(excluding: 0, excludingTitles: ownTitles).first { $0.id == target }
            print("IMAGE capturedVisible=\(capturedCount) targetHasRealImage=\(actualImage.map { !$0.usesUnavailableImage && !$0.usesApplicationIcon } ?? false)")
            let delivered = await snapshotter.click(windowID: target, mouseButton: .left, promptingForAccessibility: false, preserveCursorPosition: !menuMode)
            try? await Task.sleep(for: .milliseconds(menuMode ? 750 : 250))
            if menuMode {
                print("NATIVE_MENU opens=\(receipt.menuOpens) closesBeforeDismiss=\(receipt.menuCloses)")
                nativeMenu.cancelTracking()
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("CLICK temporarilyMoved=\(placement != nil) routed=\(delivered) nativeReceipts=\(receipt.count)")
            if let placement {
                let result = await snapshotter.restore(placement)
                print("RESTORE \(result.description)")
                try? await Task.sleep(for: .milliseconds(100))
            }
            print(String(format: "CURSOR gestures=%d maxRestoreError=%.2f", cursorRestoreErrors.count, cursorRestoreErrors.max() ?? -1))
            if let cursorBefore, let after = CGEvent(source: nil)?.location {
                print(String(format: "CURSOR displacementAfterRoundTrip=%.2f hardwareMoves=%u", hypot(after.x - cursorBefore.x, after.y - cursorBefore.y), CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved) &- hardwareBefore))
            }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { cleanup(); print("TEST_TIMEOUT_CLEANED"); app.terminate(nil) }
app.run()
