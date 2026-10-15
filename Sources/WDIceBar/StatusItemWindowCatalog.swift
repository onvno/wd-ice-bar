import CoreGraphics

struct StatusWindow {
    let id: CGWindowID
    let ownerPID: Int32
    let ownerName: String
    let ownerBundleID: String?
    let title: String
    let frame: CGRect
    var itemBundleID: String? = nil

    var isControlCenterHost: Bool {
        ownerBundleID == "com.apple.controlcenter" ||
            ["Control Center", "ControlCenter", "控制中心"].contains(ownerName)
    }

    var exclusionKey: String? {
        // A host's generic Item-0 title identifies many unrelated apps. Persist only
        // after recovering the client identity from its paired backing window.
        guard !title.isEmpty,
              let identity = itemBundleID ?? (isControlCenterHost ? nil : ownerBundleID ?? ownerName)
        else { return nil }
        return "\(identity)|\(title)"
    }
}

/// Modern macOS also enumerates backing windows translated by one display width.
/// Their height can be greater, smaller, or equal to the real item's height when
/// displays have different menu bars. Pair client bundle titles with named status
/// items; neither height ordering nor negative X identifies a backing window.
enum StatusItemWindowCatalog {
    static func realWindows(_ windows: [StatusWindow], screenWidths: [CGFloat]) -> [StatusWindow] {
        // Removed NSStatusItems can leave zero-sized host windows in the list.
        let windows = windows.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        var backingIDs: Set<CGWindowID> = []
        var clients: [CGWindowID: String] = [:]
        for backing in windows where backing.isControlCenterHost &&
            (backing.title.isEmpty || isClientIdentityTitle(backing.title)) {
            let matches = windows.filter { real in
                real.id != backing.id && real.isControlCenterHost && real.ownerPID == backing.ownerPID &&
                    !real.title.isEmpty && !isClientIdentityTitle(real.title) &&
                    abs(real.frame.minY - backing.frame.minY) <= 1 &&
                    abs(real.frame.width - backing.frame.width) <= 1 &&
                    screenWidths.contains { abs(abs(real.frame.minX - backing.frame.minX) - $0) <= 4 }
            }
            guard matches.count == 1, let real = matches.first else { continue }
            backingIDs.insert(backing.id)
            if isClientIdentityTitle(backing.title) {
                clients[real.id] = backing.title
            }
        }
        return windows.filter { !backingIDs.contains($0.id) }.map { window in
            var real = window
            real.itemBundleID = clients[window.id]
            return real
        }
    }

    private static func isClientIdentityTitle(_ title: String) -> Bool {
        title.contains(".") && !title.hasPrefix("WDIceBar.")
    }

    static func preservingIdentities(_ windows: [StatusWindow], previous: [CGWindowID: StatusWindow]) -> [StatusWindow] {
        windows.map { window in
            var current = window
            if current.itemBundleID == nil, let old = previous[current.id],
               old.ownerPID == current.ownerPID, old.title == current.title {
                current.itemBundleID = old.itemBundleID
            }
            return current
        }
    }

    /// Choose a real, movable anchor with enough room to its left. A full menu
    /// bar can still expose the target by moving one item rather than revealing all.
    static func revealAnchor(for item: StatusWindow, in windows: [StatusWindow], bounds: CGRect) -> StatusWindow? {
        windows.filter {
            $0.id != item.id && isUserMenuBarItem($0) && bounds.contains($0.frame) &&
                abs($0.frame.minY - bounds.minY) <= 1 &&
                $0.frame.minX - item.frame.width >= bounds.minX + 4
        }.max { $0.frame.minX < $1.frame.minX }
    }

    static func belongsInShelf(_ frame: CGRect, boundaryX: CGFloat, visibleBounds: CGRect?) -> Bool {
        if frame.maxX <= boundaryX { return true }
        guard let visibleBounds, abs(frame.minY - visibleBounds.minY) <= 1 else { return false }
        return !visibleBounds.contains(frame)
    }

    static func isUserMenuBarItem(_ window: StatusWindow) -> Bool {
        guard window.frame.width > 0, window.frame.height > 0 else { return false }
        if window.ownerBundleID == "com.apple.WindowServer" || window.ownerName == "Window Server" { return false }
        if window.isControlCenterHost, window.title.isEmpty { return false }
        // Control Center hosts third-party items too. Never reject its entire process.
        let reservedTitles: Set<String> = [
            "Clock", "BentoBox", "Battery", "Siri", "AudioVideoModule", "FaceTime",
            "MusicRecognition", "WiFi", "Bluetooth", "Spotlight", "NotificationCenter",
        ]
        guard window.isControlCenterHost || window.ownerBundleID == "com.apple.systemuiserver" ||
                window.ownerName == "SystemUIServer" else { return true }
        return !reservedTitles.contains { window.title == $0 || window.title.hasPrefix("\($0)-") }
    }
}
