import AppKit

@MainActor
final class WDIceBarAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showControlWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await controller.restoreBeforeTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
