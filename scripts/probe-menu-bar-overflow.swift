// Creates disposable status items for 1.5 seconds, then removes them.
// Compile for the app's deployment target before running:
// swiftc -target arm64-apple-macosx14.0 scripts/probe-menu-bar-overflow.swift -o /tmp/wd-ice-bar-overflow-probe
// /tmp/wd-ice-bar-overflow-probe
// Naturally-overflowed counts require wd-ice-bar to be running, for its divider boundary.
import AppKit
import CoreGraphics
@_silgen_name("CGSMainConnectionID") func connection() -> Int32
@_silgen_name("CGSGetWindowCount") func count(_ cid: Int32, _ target: Int32, _ n: inout Int32) -> CGError
@_silgen_name("CGSGetProcessMenuBarWindowList") func list(_ cid: Int32, _ target: Int32, _ n: Int32, _ ids: UnsafeMutablePointer<CGWindowID>, _ actual: inout Int32) -> CGError
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var items: [NSStatusItem] = []
for i in 0..<40 {
 UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position WDOverflowProbe.\(i)")
 let item = NSStatusBar.system.statusItem(withLength: 80)
 item.autosaveName = "WDOverflowProbe.\(i)"
 item.button?.title = "P\(i)"
 item.button?.window?.title = "WDOverflowProbe.\(i)"
 items.append(item)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
 var n: Int32 = 0
 _ = count(connection(), 0, &n)
 var ids = [CGWindowID](repeating: 0, count: Int(n)), actual: Int32 = 0
 _ = list(connection(), 0, n, &ids, &actual)
 var ptrs = ids.prefix(Int(actual)).map { UnsafeRawPointer(bitPattern: UInt($0)) }
 let a = CFArrayCreate(kCFAllocatorDefault, &ptrs, ptrs.count, nil)!
 let rows = CGWindowListCreateDescriptionFromArray(a) as? [[CFString:Any]] ?? []
 let dividerFrame = rows.first { ($0[kCGWindowName] as? String) == "WDIceBar.Divider.v1" }.flatMap { ($0[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
 var found = 0, offscreen = 0, captured = 0, naturalOverflow = 0
 for r in rows {
  guard let title = r[kCGWindowName] as? String, title.hasPrefix("WDOverflowProbe."),
        let id = r[kCGWindowNumber] as? CGWindowID,
        let bounds = r[kCGWindowBounds] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
  found += 1
  if frame.minX < 0 {
   offscreen += 1
   if let dividerFrame, frame.minX >= dividerFrame.maxX { naturalOverflow += 1 }
   if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]), image.width > 0 {
    captured += 1
   }
  }
 }
 print("PROBE created=40 enumerated=\(found) offscreen=\(offscreen) offscreenImageAvailable=\(captured) naturallyOverflowedOnVisibleSide=\(naturalOverflow) permission=\(CGPreflightScreenCaptureAccess())")
 for item in items { NSStatusBar.system.removeStatusItem(item) }
 for i in 0..<40 { UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position WDOverflowProbe.\(i)") }
 app.terminate(nil)
}
app.run()
