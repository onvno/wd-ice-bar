import Foundation

/// Never persist WindowServer IDs or PIDs: both can be reused by unrelated apps.
@MainActor
final class StatusItemExclusions {
    private let defaults: UserDefaults
    private let defaultsKey = "WDIceBar.ExcludedStatusItems.v1"
    private var persistentKeys: Set<String>
    private var sessionKeys: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        persistentKeys = Set((defaults.stringArray(forKey: defaultsKey) ?? []).filter {
            // Discard an ambiguous exclusion written by the previous host-based identity.
            !$0.hasPrefix("com.apple.controlcenter|Item-") && !$0.hasPrefix("控制中心|Item-") &&
                !$0.hasPrefix("Control Center|Item-")
        })
    }

    var hasExclusions: Bool { !persistentKeys.isEmpty || !sessionKeys.isEmpty }

    func contains(_ snapshot: StatusItemSnapshot) -> Bool {
        sessionKeys.contains("\(snapshot.id)|\(snapshot.key)") ||
            snapshot.exclusionKey.map { persistentKeys.contains($0) } == true
    }

    func insert(_ snapshot: StatusItemSnapshot) {
        if let key = snapshot.exclusionKey {
            persistentKeys.insert(key)
            defaults.set(persistentKeys.sorted(), forKey: defaultsKey)
        } else {
            sessionKeys.insert("\(snapshot.id)|\(snapshot.key)")
        }
    }

    func reset() {
        persistentKeys.removeAll()
        sessionKeys.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }
}
