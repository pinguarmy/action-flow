import AppKit
import ActionFlowCore

/// Owns every system notification observer and the one-second timer. It only forwards events;
/// the owner decides what they mean. Set the handlers, then call `start()`.
@MainActor
final class SystemEventObserver {
    /// An application became frontmost. Receives the application and its (possibly empty) bundle identifier.
    var onApplicationActivated: ((NSRunningApplication, String) -> Void)?
    /// A foreign application launched or terminated. Never called for this app, the login window or empty identifiers.
    var onApplicationLifecycle: ((TriggerKind, String) -> Void)?
    var onSessionTransition: ((SessionTransition) -> Void)?
    var onTick: (() -> Void)?
    /// Called synchronously on the main thread while the app terminates.
    var onWillTerminate: (() -> Void)?

    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var terminationObserver: NSObjectProtocol?

    func start() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let identifier = app.bundleIdentifier ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.onApplicationActivated?(app, identifier)
            }
        }
        for (notification, kind) in [(NSWorkspace.didLaunchApplicationNotification, TriggerKind.appLaunched), (NSWorkspace.didTerminateApplicationNotification, TriggerKind.appTerminated)] {
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName:notification,object:nil,queue:.main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let identifier = app.bundleIdentifier, !identifier.isEmpty,
                      identifier != (Bundle.main.bundleIdentifier ?? "io.github.pinguarmy.actionflow"), identifier != "com.apple.loginwindow" else { return }
                // Notification metadata only. Never launch/activate the event source.
                Task { @MainActor in self?.onApplicationLifecycle?(kind, identifier) }
            }
            lifecycleObservers.append(token)
        }
        for (notification, transition) in [(NSWorkspace.willSleepNotification, SessionTransition.willSleep), (NSWorkspace.didWakeNotification, SessionTransition.didWake), (NSWorkspace.sessionDidResignActiveNotification, SessionTransition.sessionResigned), (NSWorkspace.sessionDidBecomeActiveNotification, SessionTransition.sessionBecameActive)] {
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName:notification,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.onSessionTransition?(transition) }
            }
            lifecycleObservers.append(token)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick?() }
        }
        timer?.tolerance = 0.2
        // Termination must flush pending edits even when no window (and no SwiftUI observer) is alive.
        // A Task would never run during termination, so run synchronously on the main queue.
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onWillTerminate?()
            }
        }
    }

    /// Removes only the termination observer (shutdown does this before anything else is torn down).
    func stopObservingTermination() {
        if let token = terminationObserver { NotificationCenter.default.removeObserver(token) }
        terminationObserver = nil
    }

    /// Removes every observer and stops the timer. Safe to call repeatedly.
    func invalidate() {
        stopObservingTermination()
        timer?.invalidate()
        if let token = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObserver = nil
        for token in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        lifecycleObservers.removeAll()
    }
}
