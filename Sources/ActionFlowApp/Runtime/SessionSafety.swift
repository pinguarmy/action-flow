import AppKit
import CoreGraphics
import ActionFlowCore

/// No screen contents are read. Missing console/login identity fails closed.
/// The optional WindowServer lock marker is advisory and never used to unlock a session.
@MainActor
struct SessionSafety {
    private static var transitionState = SessionTransitionState()

    static func noteTransition(_ event: SessionTransition) { transitionState.apply(event) }

    static var allowsExecution: Bool {
        guard !transitionState.isSuspended else { return false }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue == true,
              (session[kCGSessionLoginDoneKey as String] as? NSNumber)?.boolValue == true else { return false }
        if (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true { return false }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.bundleIdentifier != "com.apple.loginwindow" else { return false }
        return true
    }
}
