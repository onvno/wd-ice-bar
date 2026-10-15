import CoreGraphics
import Foundation

enum MenuBarDismissalPolicy {
    static func isOutsideInteraction(_ point: CGPoint, itemFrame: CGRect, interfaceFrames: [CGRect]) -> Bool {
        !([itemFrame] + interfaceFrames).contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
    }

    /// Our native activation uses session input too. Its delayed delivery must
    /// not count as an outside click, even after the activation task completes.
    static func isUserInput(_ event: CGEvent?) -> Bool {
        guard let event else { return true }
        return event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid())
    }
}
