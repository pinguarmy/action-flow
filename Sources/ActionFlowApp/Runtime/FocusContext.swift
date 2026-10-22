import Foundation

/// The expected application is captured once per chain. Only a successful,
/// explicitly requested app launch may replace it. This type never reads or
/// changes the desktop and can be exercised with synthetic process identities.
@MainActor
struct FocusContext {
    private(set) var expectedProcessIdentifier: pid_t?

    init(initialProcessIdentifier: pid_t?) {
        expectedProcessIdentifier = initialProcessIdentifier
    }

    @discardableResult
    func validate(currentProcessIdentifier: pid_t?) throws -> pid_t {
        guard let expected = expectedProcessIdentifier, expected > 0,
              let current = currentProcessIdentifier, current > 0 else {
            throw FocusContextError.unavailable
        }
        guard expected == current else { throw FocusContextError.changed }
        return expected
    }

    mutating func acceptSuccessfulLaunch(processIdentifier: pid_t, currentProcessIdentifier: pid_t?) throws {
        guard processIdentifier > 0, currentProcessIdentifier == processIdentifier else {
            throw FocusContextError.launchNotFrontmost
        }
        expectedProcessIdentifier = processIdentifier
    }
}

enum FocusContextError: LocalizedError, Equatable {
    case unavailable
    case changed
    case launchNotFrontmost

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The foreground application could not be identified. Window and keyboard actions were stopped without changing focus."
        case .changed:
            return "The foreground application changed during this action chain. Window and keyboard actions were stopped to avoid affecting another app. Focus was not restored automatically."
        case .launchNotFrontmost:
            return "The requested application is not frontmost. Following window and keyboard actions were stopped."
        }
    }
}
