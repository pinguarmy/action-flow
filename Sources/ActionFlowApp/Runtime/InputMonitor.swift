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

/// A listen-only session tap. No event contents or key history are retained.
@MainActor
final class InputMonitor {
    var onEvent: ((InputEvent) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var running = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var hasInputMonitoringPermission: Bool { CGPreflightListenEventAccess() }

    func start() {
        guard !running else { return }
        // Do not call CGRequestListenEventAccess here. Permission requests belong
        // to an explicit user command, not starting or restoring automation.
        guard Self.hasInputMonitoringPermission else {
            onStatus?("Input Monitoring permission is required. Enable it in System Settings, then restart monitoring.")
            return
        }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                         options: .listenOnly, eventsOfInterest: mask,
                                         callback: actionFlowInputCallback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onStatus?("macOS could not create the passive input monitor. Check Input Monitoring permission. Secure input can hide keyboard events.")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            onStatus?("Could not attach the input monitor to the main run loop.")
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        running = true
        onStatus?("Passive input monitoring is active. Secure input and system-reserved shortcuts may not be observable.")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        running = false
    }

    fileprivate func receive(_ type: CGEventType, event: CGEvent) {
        guard running else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Stop rather than repeatedly re-enabling a tap disabled by the OS.
            stop()
            onStatus?("macOS disabled the input monitor. Restart monitoring when ready.")
            return
        }
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard let input = InputDecoder.decode(type: type, event: event, appBundleIdentifier: bundleIdentifier) else { return }
        onEvent?(input)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

private func actionFlowInputCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                       _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        // This tap is attached exclusively to the main run loop.
        MainActor.assumeIsolated {
            Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue().receive(type, event: event)
        }
    }
    // A listen-only tap must always pass the original event through.
    return Unmanaged.passUnretained(event)
}
