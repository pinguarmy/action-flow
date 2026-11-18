import AppKit
import ApplicationServices
import ActionFlowCore

/// Shared with the executor so generated input cannot trigger another rule.
let actionFlowEventMarker: Int64 = 0x47464F524745

@MainActor
struct InputEvent {
    var kind: TriggerKind
    var keyCode: UInt16
    var modifiers: ModifierKeys
    var mouseButton: Int
    var scrollDirection: ScrollDirection
    var appBundleIdentifier: String
    /// Key auto-repeat. Never triggers a rule; only decides whether an owned chord keeps the repeat.
    var isRepeat = false

    init(kind: TriggerKind = .shortcut, keyCode: UInt16 = 0,
         modifiers: ModifierKeys = [], mouseButton: Int = 0,
         scrollDirection: ScrollDirection = .up, appBundleIdentifier: String = "") {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mouseButton = mouseButton
        self.scrollDirection = scrollDirection
        self.appBundleIdentifier = appBundleIdentifier
    }
}

/// Up to two session taps on the main run loop. Mouse buttons and scrolling are always observed
/// listen-only. The keyboard tap is active only while an enabled single-press shortcut rule keeps its
/// key press and Accessibility is granted; it then drops exactly the key presses `onEvent` claims.
/// No event contents or key history are retained.
@MainActor
final class InputMonitor {
    /// Returns true to keep the key press from the active app. Honored only for key presses seen by an
    /// active keyboard tap; mouse, scroll and every other event always pass through.
    var onEvent: ((InputEvent) -> Bool)?
    var onStatus: ((String) -> Void)?
    private(set) var running = false
    /// The input kinds the current taps observe. Empty while stopped.
    private(set) var interest: TriggerInterest = []
    /// True only while an active (event-dropping) keyboard tap exists.
    private(set) var interceptsShortcuts = false
    /// The keyboard mode requested when the taps were created. A failed active tap falls back to
    /// listen-only without being retried until this request changes.
    private var keyboardRequestedActive = false
    private var keyboardTap: CFMachPort?
    private var keyboardSource: CFRunLoopSource?
    private var pointerTap: CFMachPort?
    private var pointerSource: CFRunLoopSource?
    /// Uptimes of recent in-place re-enables after a timeout. Kept across stop() so the limit is a rolling window.
    private var timeoutReenables: [TimeInterval] = []

    static var hasInputMonitoringPermission: Bool { CGPreflightListenEventAccess() }
    private static let inputKinds: TriggerInterest = [.keyboard, .mouseButtons, .scroll]
    private static let maximumTimeoutReenables = 3
    private static let timeoutReenableWindow: TimeInterval = 60

    private enum TapError: Error { case creation, runLoop }

    /// Observes only the event types the given interest needs. Recreates the taps when the input
    /// interest or the wanted keyboard mode (active needs `.shortcutInterception` and Accessibility)
    /// changes; does nothing when both are unchanged or no input is needed at all.
    func start(interest requested: TriggerInterest = [.keyboard, .mouseButtons, .scroll]) {
        let wanted = requested.intersection(Self.inputKinds)
        let wantsActiveKeyboard = wanted.contains(.keyboard) && requested.contains(.shortcutInterception) && AXIsProcessTrusted()
        if running {
            if interest == wanted && keyboardRequestedActive == wantsActiveKeyboard { return }
            stop()
        }
        guard !wanted.isEmpty else { return }
        // Do not call CGRequestListenEventAccess here. Permission requests belong
        // to an explicit user command, not starting or restoring automation.
        guard Self.hasInputMonitoringPermission else {
            onStatus?(AppLocalization.text("Input Monitoring permission is required. Enable it in System Settings, then restart monitoring."))
            return
        }
        var pointerTypes: [CGEventType] = []
        if wanted.contains(.mouseButtons) { pointerTypes.append(contentsOf: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) }
        if wanted.contains(.scroll) { pointerTypes.append(.scrollWheel) }
        var keyboard: (tap: CFMachPort, source: CFRunLoopSource)?
        var pointer: (tap: CFMachPort, source: CFRunLoopSource)?
        var keyboardActive = false
        do {
            if wanted.contains(.keyboard) {
                if wantsActiveKeyboard, let activeTap = try? makeTap(types: [.keyDown], active: true) {
                    keyboard = activeTap
                    keyboardActive = true
                } else {
                    keyboard = try makeTap(types: [.keyDown], active: false)
                }
            }
            if !pointerTypes.isEmpty { pointer = try makeTap(types: pointerTypes, active: false) }
        } catch {
            // All or nothing: a partial monitor would silently miss triggers. tick() retries.
            if let keyboard { CFMachPortInvalidate(keyboard.tap) }
            if let pointer { CFMachPortInvalidate(pointer.tap) }
            if (error as? TapError) == .runLoop {
                onStatus?(AppLocalization.text("Could not attach the input monitor to the main run loop."))
            } else {
                onStatus?(AppLocalization.text("macOS could not create the input monitor. Check Input Monitoring permission. Secure input can hide keyboard events."))
            }
            return
        }
        keyboardTap = keyboard?.tap
        keyboardSource = keyboard?.source
        pointerTap = pointer?.tap
        pointerSource = pointer?.source
        for source in [keyboardSource, pointerSource].compactMap({ $0 }) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        for tap in [keyboardTap, pointerTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap, enable: true) }
        interest = wanted
        keyboardRequestedActive = wantsActiveKeyboard
        interceptsShortcuts = keyboardActive
        running = true
        if keyboardActive {
            onStatus?(AppLocalization.text("Input monitoring is active. Shortcut rules keep their key presses from reaching other apps. Secure input and system-reserved shortcuts may not be observable."))
        } else if wantsActiveKeyboard {
            onStatus?(AppLocalization.text("Input monitoring is active, but macOS did not allow ActionFlow to keep shortcut key presses. They still reach the active app."))
        } else {
            onStatus?(AppLocalization.text("Passive input monitoring is active. Secure input and system-reserved shortcuts may not be observable."))
        }
    }

    /// An active tap is inserted at the head so it sees key presses before other apps; a listen-only tap
    /// is appended at the tail exactly as before.
    private func makeTap(types: [CGEventType], active: Bool) throws -> (tap: CFMachPort, source: CFRunLoopSource) {
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                         place: active ? .headInsertEventTap : .tailAppendEventTap,
                                         options: active ? .defaultTap : .listenOnly, eventsOfInterest: mask,
                                         callback: actionFlowInputCallback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw TapError.creation
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw TapError.runLoop
        }
        return (tap: tap, source: source)
    }

    func stop() {
        for tap in [keyboardTap, pointerTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap, enable: false) }
        for source in [keyboardSource, pointerSource].compactMap({ $0 }) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        for tap in [keyboardTap, pointerTap].compactMap({ $0 }) { CFMachPortInvalidate(tap) }
        keyboardSource = nil
        keyboardTap = nil
        pointerSource = nil
        pointerTap = nil
        running = false
        interest = []
        interceptsShortcuts = false
        keyboardRequestedActive = false
    }

    /// Returns true only when the event is a key press that an active keyboard tap should drop.
    fileprivate func receive(_ type: CGEventType, event: CGEvent) -> Bool {
        guard running else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A slow main thread can time out a tap. Re-enable in place a few times so owned
            // shortcuts do not leak; otherwise stop rather than repeatedly re-enabling it.
            if type == .tapDisabledByTimeout && reenableAfterTimeout() { return false }
            stop()
            onStatus?(AppLocalization.text("macOS disabled the input monitor. Restart monitoring when ready."))
            return false
        }
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard let input = InputDecoder.decode(type: type, event: event, appBundleIdentifier: bundleIdentifier) else { return false }
        let claimed = onEvent?(input) ?? false
        // Read after onEvent: only a key press seen while an active keyboard tap exists may be dropped.
        return claimed && type == .keyDown && interceptsShortcuts
    }

    private func reenableAfterTimeout() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        timeoutReenables = timeoutReenables.filter { now - $0 < Self.timeoutReenableWindow }
        guard timeoutReenables.count < Self.maximumTimeoutReenables else { return false }
        timeoutReenables.append(now)
        for tap in [keyboardTap, pointerTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap, enable: true) }
        return true
    }

    deinit {
        if let keyboardSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardSource, .commonModes) }
        if let pointerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), pointerSource, .commonModes) }
        if let keyboardTap { CFMachPortInvalidate(keyboardTap) }
        if let pointerTap { CFMachPortInvalidate(pointerTap) }
    }
}

private func actionFlowInputCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                       _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    var drop = false
    if let userInfo {
        // Both taps are attached exclusively to the main run loop.
        drop = MainActor.assumeIsolated {
            Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue().receive(type, event: event)
        }
    }
    // The only dropped events: key presses of an owned shortcut, seen by an active keyboard tap.
    // Listen-only taps, tap-disabled notices, mouse, scroll and self-generated input always pass through.
    if drop && type == .keyDown { return nil }
    return Unmanaged.passUnretained(event)
}
