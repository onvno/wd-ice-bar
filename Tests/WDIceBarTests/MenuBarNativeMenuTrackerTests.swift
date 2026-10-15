import Testing
@testable import WDIceBar

@MainActor
struct MenuBarNativeMenuTrackerTests {
    private func dismissalSamples(for visibility: [Bool], userDismissalAt sample: Int? = nil) -> [Int] {
        var state = MenuBarNativeMenuTracker.DismissalState()
        return visibility.enumerated().compactMap { index, visible in
            if index + 1 == sample { state.requestDismissal() }
            return state.observe(isVisible: visible) ? index + 1 : nil
        }
    }

    @Test func unrecognizedInterfaceDoesNotTimeOutAndHideItsAnchor() {
        // Ten seconds without a recognized window must not hide a custom popover.
        let dismissals = dismissalSamples(for: Array(repeating: false, count: 100))
        #expect(dismissals.isEmpty)
    }

    @Test func menuClosingOnItsOwnDoesNotHideTheRetainedIcon() {
        let visibility = Array(repeating: false, count: 30) +
            Array(repeating: true, count: 20) + Array(repeating: false, count: 100)
        #expect(dismissalSamples(for: visibility).isEmpty)
    }

    @Test func briefGapBetweenMenuAndPopoverDoesNotEndInteraction() {
        // The old two-sample rule hid the anchor during this transition.
        let visibility = [true, false, false, false, true] + Array(repeating: false, count: 8)
        #expect(dismissalSamples(for: visibility, userDismissalAt: 2) == [13])
    }

    @Test func repeatedTransientGapsNeverAccumulateIntoDismissal() {
        let visibility = (0..<10).flatMap { _ in [true, false, false, false, false, false] }
        #expect(dismissalSamples(for: visibility, userDismissalAt: 2).isEmpty)
    }

    @Test func userClickOrEscapeCanFinishAnUnrecognizedMenu() {
        let visibility = Array(repeating: false, count: 37)
        #expect(dismissalSamples(for: visibility, userDismissalAt: 30) == [37])
    }

    @Test func userDismissalWaitsForAnOpenMenuToClose() {
        let visibility = Array(repeating: true, count: 30) + Array(repeating: false, count: 8)
        #expect(dismissalSamples(for: visibility, userDismissalAt: 5) == [38])
    }

    @Test func userLeavingTheWholeMenuCanDismissItEvenWhenStillVisible() {
        var state = MenuBarNativeMenuTracker.DismissalState()
        state.observePointer(isOutside: true)
        let results = (0..<8).map { _ in state.observe(isVisible: true) }
        #expect(results == Array(repeating: false, count: 7) + [true])
    }

    @Test func returningToTheMenuCancelsPointerDismissal() {
        var state = MenuBarNativeMenuTracker.DismissalState()
        state.observePointer(isOutside: true)
        let beforeReturn = (0..<5).map { _ in state.observe(isVisible: true) }
        state.observePointer(isOutside: false)
        let afterReturn = (0..<20).map { _ in state.observe(isVisible: false) }
        #expect(beforeReturn.allSatisfy { !$0 })
        #expect(afterReturn.allSatisfy { !$0 })
    }
}
