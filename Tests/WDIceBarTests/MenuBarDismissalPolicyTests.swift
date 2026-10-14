import CoreGraphics
import Foundation
import Testing
@testable import WDIceBar

struct MenuBarDismissalPolicyTests {
    @Test func delayedSyntheticClicksDoNotDismissTheirOwnMenu() throws {
        let event = try #require(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        #expect(event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()))
        #expect(!MenuBarDismissalPolicy.isUserInput(event))
    }

    @Test func realUserClicksAndEscapeRemainEligible() throws {
        let event = try #require(CGEvent(source: nil))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        #expect(MenuBarDismissalPolicy.isUserInput(event))
        #expect(MenuBarDismissalPolicy.isUserInput(nil))
    }
}
