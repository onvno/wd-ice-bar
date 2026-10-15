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

    @Test func movingIntoMenuOrSubmenuDoesNotCountAsLeavingInteraction() {
        let icon = CGRect(x: -400, y: 0, width: 30, height: 30)
        let menu = CGRect(x: -500, y: 30, width: 200, height: 300)
        let submenu = CGRect(x: -300, y: 100, width: 180, height: 160)
        for point in [CGPoint(x: -390, y: 15), CGPoint(x: -450, y: 120), CGPoint(x: -200, y: 130)] {
            #expect(!MenuBarDismissalPolicy.isOutsideInteraction(point, itemFrame: icon, interfaceFrames: [menu, submenu]))
        }
        #expect(MenuBarDismissalPolicy.isOutsideInteraction(CGPoint(x: -900, y: 600), itemFrame: icon, interfaceFrames: [menu, submenu]))
    }
}
