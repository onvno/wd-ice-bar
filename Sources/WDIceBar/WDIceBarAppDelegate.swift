import AppKit

@MainActor
final class WDIceBarAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
