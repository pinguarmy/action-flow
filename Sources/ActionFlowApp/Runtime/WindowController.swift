import AppKit
import ApplicationServices
import ActionFlowCore

@MainActor
final class WindowController {
    private struct SavedFrame {
        let pid: pid_t
        let window: AXUIElement
        let frame: CGRect
    }
    private var savedFrames: [SavedFrame] = []

    func perform(_ operation: WindowOperation, expectedProcessIdentifier: pid_t?,
                 validateFocus: () throws -> Void) throws {
        try validateFocus()
        guard AXIsProcessTrusted() else { throw RuntimeError.message("Window actions require Accessibility permission.") }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw RuntimeError.message("There is no frontmost application.")
        }
        guard application.processIdentifier == expectedProcessIdentifier else { throw FocusContextError.changed }
        let pid = application.processIdentifier
        let window = try AXFocus.readFocusedWindow(pid: pid)
        // Capture per window action. An earlier shortcut may intentionally have
        // changed the focused window; only changes during this action are denied.
        let windowGuard = FocusedElementGuard(captured: window) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw FocusContextError.changed
            }
            return try AXFocus.readFocusedWindow(pid: pid)
        }
        let original = try frame(of: window)
        guard !NSScreen.screens.isEmpty else { throw RuntimeError.message("No display is available.") }
        let screenRects = NSScreen.screens.map { accessibilityRect($0.visibleFrame) }
        let savedFrame = savedFrames.first {
            $0.pid == application.processIdentifier && CFEqual($0.window, window)
        }?.frame
        let target = try WindowLayout.target(for: operation, original: original,
                                             screens: screenRects, restoreFrame: savedFrame)
        if operation != .restore && !savedFrames.contains(where: {
            $0.pid == application.processIdentifier && CFEqual($0.window, window)
        }) {
            // Bounded, in-memory session history. No titles or document paths.
            if savedFrames.count >= 128 { savedFrames.removeFirst() }
            savedFrames.append(SavedFrame(pid: application.processIdentifier, window: window, frame: original))
        }
        try setFrame(target, on: window) {
            try validateFocus()
            try windowGuard.validate()
        }
        if operation == .restore {
            savedFrames.removeAll { $0.pid == application.processIdentifier && CFEqual($0.window, window) }
        }
    }

    private func accessibilityRect(_ frame: CGRect) -> CGRect {
        // AX uses top-left coordinates relative to the primary display, while
        // NSScreen uses bottom-left coordinates, including on stacked displays.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    private func frame(of window: AXUIElement) throws -> CGRect {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw RuntimeError.message("This application does not expose its window position and size.")
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else {
            throw RuntimeError.message("The application returned invalid window geometry.")
        }
        return CGRect(origin: point, size: dimensions)
    }

    private func setFrame(_ frame: CGRect, on window: AXUIElement, validateFocus: () throws -> Void) throws {
        var positionSettable: DarwinBoolean = false
        var sizeSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success,
              AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success,
              positionSettable.boolValue, sizeSettable.boolValue else {
            throw RuntimeError.message("This window cannot be moved and resized through public Accessibility APIs. Full-screen and protected windows may not support tiling.")
        }
        var point = frame.origin
        var dimensions = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &dimensions) else {
            throw RuntimeError.message("Could not create the requested window geometry.")
        }
        // Size first, then position. Applications may enforce minimum sizes.
        try validateFocus()
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        // A focus change between AX calls stops remaining writes. The first
        // resize may already have happened and cannot be safely rolled back.
        try validateFocus()
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        guard sizeResult == .success, positionResult == .success else {
            throw RuntimeError.message("The application rejected part of the window change. Its frame may be partially changed.")
        }
        try validateFocus()
        let actual = try self.frame(of: window)
        guard abs(actual.minX - frame.minX) <= 4, abs(actual.minY - frame.minY) <= 4,
              abs(actual.width - frame.width) <= 4, abs(actual.height - frame.height) <= 4 else {
            throw RuntimeError.message("The application constrained the requested window frame, for example because of a minimum size. The window may be partially changed.")
        }
    }
}
