import ApplicationServices
import ActionFlowCore

/// Field conversion only. Never queries permissions or the foreground app,
/// installs an event tap, reads typed text, or posts an event.
@MainActor
enum InputDecoder {
    static func decode(type: CGEventType, event: CGEvent, appBundleIdentifier: String) -> InputEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != actionFlowEventMarker else { return nil }
        var input = InputEvent(appBundleIdentifier: appBundleIdentifier)
        input.modifiers = modifiers(from: event.flags)
        switch type {
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard (0...Int64(UInt16.max)).contains(keyCode) else { return nil }
            // Double-press recognition belongs to RuleScheduler. Physical key
            // presses always enter the scheduler as ordinary shortcut signals.
            input.kind = .shortcut
            input.keyCode = UInt16(keyCode)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard button >= 0 else { return nil }
            input.kind = .mouseButton
            input.mouseButton = Int(clamping: button)
        case .scrollWheel:
            guard let delta = scrollDelta(event) else { return nil }
            input.kind = .scroll
            // Preserve the existing physical event sign convention, independent
            // of a view's content coordinates. An exact diagonal favors vertical.
            if abs(delta.vertical) >= abs(delta.horizontal) {
                input.scrollDirection = delta.vertical > 0 ? .up : .down
            } else {
                input.scrollDirection = delta.horizontal > 0 ? .left : .right
            }
        default:
            return nil
        }
        return input
    }

    private static func modifiers(from flags: CGEventFlags) -> ModifierKeys {
        var result: ModifierKeys = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }

    private static func scrollDelta(_ event: CGEvent) -> (vertical: Double, horizontal: Double)? {
        // Choose a complete representation for both axes, never mix point and
        // wheel units. Double reads preserve fractional trackpad movement that
        // getIntegerValueField would truncate to zero.
        let representations: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2)
        ]
        for (verticalField, horizontalField) in representations {
            let vertical = event.getDoubleValueField(verticalField)
            let horizontal = event.getDoubleValueField(horizontalField)
            guard vertical.isFinite, horizontal.isFinite else { return nil }
            if vertical != 0 || horizontal != 0 { return (vertical, horizontal) }
        }
        return nil
    }
}
