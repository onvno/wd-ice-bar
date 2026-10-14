import AppKit
import Testing
@testable import WDIceBar

@MainActor
struct StatusItemExclusionsTests {
    private func snapshot(id: UInt32, pid: Int = 10, identity: String? = "app.example|Status") -> StatusItemSnapshot {
        StatusItemSnapshot(id: id, key: "\(pid)|Example|Status", exclusionKey: identity,
                           image: NSImage(size: NSSize(width: 20, height: 20)), label: "Status")
    }

    @Test func persistsAcrossProcessAndWindowChangesAndCanRestore() throws {
        let suite = "WDIceBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exclusions = StatusItemExclusions(defaults: defaults)
        exclusions.insert(snapshot(id: 1))
        let reloaded = StatusItemExclusions(defaults: defaults)
        #expect(reloaded.contains(snapshot(id: 2, pid: 20)))
        #expect(!reloaded.contains(snapshot(id: 3, identity: "another.app|Status")))
        reloaded.reset()
        #expect(!reloaded.hasExclusions)
        #expect(!StatusItemExclusions(defaults: defaults).contains(snapshot(id: 1)))
    }

    @Test func unnamedItemsAreScopedToWindowAndSession() throws {
        let suite = "WDIceBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exclusions = StatusItemExclusions(defaults: defaults)
        exclusions.insert(snapshot(id: 1, identity: nil))
        #expect(exclusions.contains(snapshot(id: 1, identity: nil)))
        #expect(!exclusions.contains(snapshot(id: 2, identity: nil)))
        #expect(!exclusions.contains(snapshot(id: 1, pid: 20, identity: nil)))
        #expect(!StatusItemExclusions(defaults: defaults).hasExclusions)
    }

    @Test func sharedHostTitleDoesNotExcludeAnotherAppAndOldAmbiguousRulesAreIgnored() throws {
        let suite = "WDIceBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["com.apple.controlcenter|Item-0", "控制中心|Item-0", "Control Center|Item-0"],
                     forKey: "WDIceBar.ExcludedStatusItems.v1")
        let exclusions = StatusItemExclusions(defaults: defaults)
        #expect(!exclusions.hasExclusions)
        exclusions.insert(snapshot(id: 1, identity: "com.example.first|Item-0"))
        #expect(exclusions.contains(snapshot(id: 2, pid: 20, identity: "com.example.first|Item-0")))
        #expect(!exclusions.contains(snapshot(id: 3, identity: "com.example.second|Item-0")))
    }

}
