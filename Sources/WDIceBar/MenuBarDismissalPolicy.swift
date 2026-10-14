import CoreGraphics
import Foundation

enum MenuBarDismissalPolicy {
    /// Our native activation uses session input too. Its delayed delivery must
    /// not count as an outside click, even after the activation task completes.
    static func isUserInput(_ event: CGEvent?) -> Bool {
        guard let event else { return true }
        return event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid())
    }
}
