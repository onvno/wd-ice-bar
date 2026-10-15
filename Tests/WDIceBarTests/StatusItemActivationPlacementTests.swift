import CoreGraphics
import Testing
@testable import WDIceBar

@MainActor
struct StatusItemActivationPlacementTests {
    private let bounds = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

    @Test func stableVisibleItemIsReadyWithoutAnyParticularNeighbour() {
        var placement = StatusItemSnapshotter.VisiblePlacement(bounds: bounds)
        let frame = CGRect(x: -400, y: 0, width: 38, height: 30)
        let first = placement.observe(frame)
        let second = placement.observe(frame)
        #expect(!first)
        #expect(second)
    }

    @Test func changingPositionMustSettleBeforeClicking() {
        var placement = StatusItemSnapshotter.VisiblePlacement(bounds: bounds)
        let initial = CGRect(x: -400, y: 0, width: 38, height: 30)
        let final = CGRect(x: -380, y: 0, width: 38, height: 30)
        let first = placement.observe(initial)
        let moving = placement.observe(final)
        let stable = placement.observe(final)
        #expect(!first)
        #expect(!moving)
        #expect(stable)
    }

    @Test func offscreenMissingAndNonMenuFramesResetConfirmation() {
        let visible = CGRect(x: -400, y: 0, width: 38, height: 30)
        let invalid: [CGRect?] = [nil, .zero,
            CGRect(x: -1930, y: 0, width: 38, height: 30),
            CGRect(x: -400, y: 300, width: 38, height: 30)]
        for frame in invalid {
            var placement = StatusItemSnapshotter.VisiblePlacement(bounds: bounds)
            _ = placement.observe(visible)
            let rejected = placement.observe(frame)
            let firstAfterGap = placement.observe(visible)
            let stable = placement.observe(visible)
            #expect(!rejected)
            #expect(!firstAfterGap)
            #expect(stable)
        }
    }
}
