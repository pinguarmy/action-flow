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
        guard AXIsProcessTrusted() else { throw RuntimeError.message(AppLocalization.text("Window actions require Accessibility permission.")) }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw RuntimeError.message(AppLocalization.text("There is no frontmost application."))
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
        guard !NSScreen.screens.isEmpty else { throw RuntimeError.message(AppLocalization.text("No display is available.")) }
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
            throw RuntimeError.message(AppLocalization.text("This application does not expose its window position and size."))
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else {
            throw RuntimeError.message(AppLocalization.text("The application returned invalid window geometry."))
        }
        return CGRect(origin: point, size: dimensions)
    }

    private func setFrame(_ frame: CGRect, on window: AXUIElement, validateFocus: () throws -> Void) throws {
        var positionSettable: DarwinBoolean = false
        var sizeSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success,
              AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success,
              positionSettable.boolValue, sizeSettable.boolValue else {
            throw RuntimeError.message(AppLocalization.text("This window cannot be moved and resized through public Accessibility APIs. Full-screen and protected windows may not support tiling."))
        }
        var point = frame.origin
        var dimensions = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &dimensions) else {
            throw RuntimeError.message(AppLocalization.text("Could not create the requested window geometry."))
        }
        let rejected = RuntimeError.message(AppLocalization.text("The application rejected part of the window change. Its frame may be partially changed."))
        let tolerance: CGFloat = 4
        // Order: size, position, then (only if needed) size again and position
        // again. The first resize happens on the display the window currently
        // occupies, which may clamp it (moving to a larger display, or growing
        // near a screen edge); repeating the resize at the final position fixes
        // that. Some applications move themselves when resized, so the origin
        // is nudged once more if it drifted.
        // A focus change between AX calls stops remaining writes. Earlier
        // writes may already have happened and cannot be safely rolled back.
        try validateFocus()
        var sizeAccepted = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        try validateFocus()
        guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success else {
            throw rejected
        }
        try validateFocus()
        var actual = try self.frame(of: window)
        if !sizeAccepted || abs(actual.width - frame.width) > tolerance || abs(actual.height - frame.height) > tolerance {
            try validateFocus()
            if AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success {
                sizeAccepted = true
            }
            try validateFocus()
            actual = try self.frame(of: window)
        }
        guard sizeAccepted else { throw rejected }
        if abs(actual.minX - frame.minX) > tolerance || abs(actual.minY - frame.minY) > tolerance {
            try validateFocus()
            guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success else {
                throw rejected
            }
            try validateFocus()
            actual = try self.frame(of: window)
        }
        // A remaining difference is the application's own constraint (minimum
        // size, character-cell resize increments in Terminal or iTerm, and so
        // on). The window did move and resize as far as the app allows, so this
        // is accepted rather than reported as a failure that would abort the
        // rest of the action chain. `frame(of:)` above still throws when the
        // final geometry is invalid.
        _ = actual
    }
}
