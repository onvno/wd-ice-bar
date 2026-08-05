import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = WDIceBarAppDelegate()
application.delegate = delegate
application.run()
