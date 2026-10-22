import ApplicationServices

/// Pins a single action to an AX identity, never to a title, value, or document
/// path. A new guard is captured per action, not across intentional shortcuts.
@MainActor
struct FocusedElementGuard {
    private let captured: AXUIElement
    private let current: () throws -> AXUIElement

    init(current: @escaping () throws -> AXUIElement) throws {
        do { captured = try current() }
        catch { throw FocusedElementError.unavailable }
        self.current = current
    }

    init(captured: AXUIElement, current: @escaping () throws -> AXUIElement) {
        self.captured = captured
        self.current = current
    }

    func validate() throws {
        let element: AXUIElement
        do { element = try current() }
        catch { throw FocusedElementError.unavailable }
        guard CFEqual(captured, element) else { throw FocusedElementError.changed }
    }
}

enum FocusedElementError: LocalizedError, Equatable {
    case changed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .changed:
            return "The focused window or input element changed during this action. Remaining changes were stopped without restoring focus. An earlier change may already have occurred."
        case .unavailable:
            return "The focused window or input element is unavailable through Accessibility. Remaining changes were stopped without restoring focus."
        }
    }
}

/// Read identity attributes only. Callers must check Accessibility permission
/// and expected foreground PID first. No titles, text, selections, or values.
@MainActor
enum AXFocus {
    static func readFocusedWindow(pid: pid_t) throws -> AXUIElement {
        try read(attribute: kAXFocusedWindowAttribute as CFString, pid: pid)
    }

    static func readFocusedElement(pid: pid_t) throws -> AXUIElement {
        try read(attribute: kAXFocusedUIElementAttribute as CFString, pid: pid)
    }

    private static func read(attribute: CFString, pid: pid_t) throws -> AXUIElement {
        guard pid > 0 else { throw FocusedElementError.unavailable }
        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, 0.25) == .success else {
            throw FocusedElementError.unavailable
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw FocusedElementError.unavailable
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid,
              AXUIElementSetMessagingTimeout(element, 0.25) == .success else {
            throw FocusedElementError.unavailable
        }
        return element
    }
}
