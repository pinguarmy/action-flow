import AppKit
import ActionFlowCore

/// Captures one key chord with a local key-down monitor. The owner must call `stop()` from its
/// `onRecorded` and `onEnd` handlers; the recorder never stops itself.
@MainActor
final class ShortcutRecorder {
    private var token: Any?
    private var timeout: Task<Void, Never>?
    private var onRecorded: ((UInt16, ModifierKeys) -> Void)?
    private var onEnd: (() -> Void)?

    var isRecording: Bool { token != nil }

    /// `onRecorded` receives a chord; `onEnd` is called for Escape and after the 15 second timeout.
    func start(onRecorded: @escaping (UInt16, ModifierKeys) -> Void, onEnd: @escaping () -> Void) {
        stop()
        self.onRecorded = onRecorded
        self.onEnd = onEnd
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            var consume = false
            MainActor.assumeIsolated {
                guard let self else { return }
                consume = true
                guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != actionFlowEventMarker else { return }
                if event.keyCode == 53 { self.onEnd?(); return }
                var modifiers: ModifierKeys = []
                if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
                if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
                if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
                if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
                self.onRecorded?(event.keyCode, modifiers)
            }
            return consume ? nil : event
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { self?.onEnd?() }
        }
    }

    func stop() {
        if let existing = token { NSEvent.removeMonitor(existing) }
        token = nil
        timeout?.cancel()
        timeout = nil
    }
}
