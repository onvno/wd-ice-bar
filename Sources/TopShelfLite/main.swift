import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = TopShelfLiteAppDelegate()
application.delegate = delegate
application.run()
