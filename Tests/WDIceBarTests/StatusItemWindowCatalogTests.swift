import CoreGraphics
import Testing
@testable import WDIceBar

struct StatusItemWindowCatalogTests {
    private func window(_ id: UInt32, title: String, x: CGFloat, width: CGFloat = 38, height: CGFloat = 33) -> StatusWindow {
        StatusWindow(id: id, ownerPID: 100, ownerName: "控制中心", ownerBundleID: "com.apple.controlcenter",
                     title: title, frame: CGRect(x: x, y: 0, width: width, height: height))
    }

    @Test func hostedThirdPartyItemsAreKeptWhileSystemControlsAreRejected() {
        #expect(StatusItemWindowCatalog.isUserMenuBarItem(window(1, title: "Item-0", x: 100)))
        for title in ["Clock", "BentoBox-0", "Battery"] {
            #expect(!StatusItemWindowCatalog.isUserMenuBarItem(window(2, title: title, x: 200)))
        }
    }

    @Test func backingCopiesDoNotBecomeIconsAndRecoverClientIdentity() throws {
        // Recorded geometry from the user's 1728-point display: host copies are
        // translated by 1730 points and have height 30 rather than 33.
        let real = window(1, title: "Item-0", x: 1325, width: 33)
        let backing = window(2, title: "com.example.translate", x: -405, width: 33, height: 30)
        let catalog = StatusItemWindowCatalog.realWindows([real, backing], screenWidths: [1728, 1920])
        #expect(catalog.map(\.id) == [1])
        let item = try #require(catalog.first)
        #expect(item.itemBundleID == "com.example.translate")
        #expect(item.exclusionKey == "com.example.translate|Item-0")
    }

    @Test func genuinelyHiddenItemsAreKeptAndOwnDividerRemainsDiscoverable() {
        let divider = window(1, title: "WDIceBar.Divider.v1", x: -3842, width: 5016)
        let dividerBacking = window(2, title: "local.wd-ice-bar", x: -5572, width: 5016, height: 30)
        let hidden = window(3, title: "Item-0", x: -3924)
        let hiddenBacking = window(4, title: "com.example.capture", x: -5654, height: 30)
        let catalog = StatusItemWindowCatalog.realWindows([divider, dividerBacking, hidden, hiddenBacking], screenWidths: [1728])
        #expect(catalog.map(\.id) == [1, 3])
        #expect(catalog.first?.frame.minX == -3842)
    }

    @Test func unpairedCandidatesAreKeptWithoutAmbiguousPersistentIdentity() {
        let item = window(1, title: "Item-0", x: -2000)
        #expect(StatusItemWindowCatalog.realWindows([item], screenWidths: [1728]).map(\.id) == [1])
        #expect(item.exclusionKey == nil)
    }

    @Test func ambiguousBackingMatchDoesNotRemoveRealCandidates() {
        let first = window(1, title: "Item-0", x: 100)
        let second = window(2, title: "Item-1", x: 102)
        let backing = window(3, title: "com.example.app", x: -1630, height: 30)
        let catalog = StatusItemWindowCatalog.realWindows([first, second, backing], screenWidths: [1728])
        #expect(catalog.map(\.id) == [1, 2, 3])
        #expect(catalog.allSatisfy { $0.itemBundleID == nil })
    }

    @Test func independentAppNamedClockIsNotAClockSystemControl() {
        let item = StatusWindow(id: 1, ownerPID: 200, ownerName: "Example",
                                ownerBundleID: "com.example.app", title: "Clock",
                                frame: CGRect(x: 100, y: 0, width: 38, height: 33))
        #expect(StatusItemWindowCatalog.isUserMenuBarItem(item))
    }


    @Test func naturallyOverflowedVisibleGroupItemsBelongInShelf() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let overflow = CGRect(x: -50, y: 0, width: 38, height: 33)
        #expect(StatusItemWindowCatalog.belongsInShelf(overflow, boundaryX: -4000, visibleBounds: display))
        #expect(!StatusItemWindowCatalog.belongsInShelf(overflow, boundaryX: -4000, visibleBounds: nil))
        let visible = CGRect(x: 1300, y: 0, width: 38, height: 33)
        #expect(!StatusItemWindowCatalog.belongsInShelf(visible, boundaryX: -4000, visibleBounds: display))
        let hidden = CGRect(x: -5000, y: 0, width: 38, height: 33)
        #expect(StatusItemWindowCatalog.belongsInShelf(hidden, boundaryX: -4000, visibleBounds: display))
    }

    @Test func clippedItemsAndNotchOcclusionAreOverflowButOtherDisplayRowsAreNot() {
        let rightArea = CGRect(x: 900, y: 0, width: 828, height: 1117)
        #expect(StatusItemWindowCatalog.belongsInShelf(CGRect(x: 880, y: 0, width: 38, height: 33), boundaryX: 10, visibleBounds: rightArea))
        #expect(!StatusItemWindowCatalog.belongsInShelf(CGRect(x: 880, y: 200, width: 38, height: 33), boundaryX: 10, visibleBounds: rightArea))
    }

    @Test func losingMirrorWindowsPreservesKnownClientButNeverReusesAnotherIdentity() throws {
        var known = window(1, title: "Item-0", x: 100)
        known.itemBundleID = "com.example.first"
        let current = window(1, title: "Item-0", x: -5000)
        let restored = StatusItemWindowCatalog.preservingIdentities([current], previous: [1: known])
        #expect(restored.first?.itemBundleID == "com.example.first")
        let changedTitle = window(1, title: "Item-1", x: -5000)
        #expect(StatusItemWindowCatalog.preservingIdentities([changedTitle], previous: [1: known]).first?.itemBundleID == nil)
        let changedProcess = StatusWindow(id: 1, ownerPID: 200, ownerName: "控制中心", ownerBundleID: "com.apple.controlcenter",
                                          title: "Item-0", frame: current.frame)
        #expect(StatusItemWindowCatalog.preservingIdentities([changedProcess], previous: [1: known]).first?.itemBundleID == nil)
    }

    @Test func revealUsesVisibleMovableAnchorAndSkipsFixedSystemItems() {
        let bounds = CGRect(x: 900, y: 0, width: 828, height: 1117)
        let source = window(1, title: "Item-0", x: -5000, width: 96)
        let tooCloseToNotch = window(2, title: "Item-0", x: 920)
        let target = window(3, title: "WDIceBar.Toggle.v1", x: 1400)
        let clock = window(4, title: "Clock", x: 1600)
        #expect(StatusItemWindowCatalog.revealAnchor(for: source, in: [source, tooCloseToNotch, target, clock], bounds: bounds)?.id == 3)
        #expect(StatusItemWindowCatalog.revealAnchor(for: source, in: [source, tooCloseToNotch, clock], bounds: bounds) == nil)
    }

    @Test func realUnknownHostedItemIsRetainedButAnonymousHostCopyIsNotACandidate() {
        #expect(StatusItemWindowCatalog.isUserMenuBarItem(window(1, title: "Item-0", x: -5000)))
        #expect(!StatusItemWindowCatalog.isUserMenuBarItem(window(2, title: "", x: -5000)))
    }

}
