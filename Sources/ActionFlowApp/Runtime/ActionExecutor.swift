import AppKit
import ApplicationServices
import Darwin
import ActionFlowCore
import UserNotifications

@MainActor
final class ActionExecutor {
    var allowScripts = false
    var onProgress: ((ExecutionProgress) -> Void)?
    private var executing = false
    private var cancellationGeneration: UInt64 = 0
    private var windowController = WindowController()
    private let menuCommandController: MenuCommandController
    private let maximumChainDuration: TimeInterval = ActionPreflight.chainDeadlineSeconds
    private let foregroundProcessIdentifier: () -> pid_t?
    private let sessionAllowsExecution: @MainActor () -> Bool

    init(foregroundProcessIdentifier: @escaping () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }, sessionAllowsExecution: @escaping @MainActor () -> Bool = { SessionSafety.allowsExecution },
         menuCommandController: MenuCommandController? = nil) {
        self.foregroundProcessIdentifier = foregroundProcessIdentifier
        self.sessionAllowsExecution = sessionAllowsExecution
        self.menuCommandController = menuCommandController ?? MenuCommandController()
    }

    /// Stops the current chain at its next cancellation point. Posted events and
    /// actions already accepted by another application cannot be undone.
    func cancel() { cancellationGeneration &+= 1 }

    func execute(_ actions: [AutomationAction]) async throws -> String {
        guard !executing else { throw RuntimeError.message("Another action chain is still running.") }
        let preflightErrors = ActionPreflight.errors(for: actions)
        guard preflightErrors.isEmpty else { throw RuntimeError.message(preflightErrors.joined(separator: " ")) }
        guard allowScripts || !actions.contains(where: { $0.kind == .shellScript }) else {
            throw RuntimeError.message("Shell scripts are disabled. No steps were run. Enable scripts explicitly in Settings before running this chain.")
        }
        executing = true
        defer { executing = false }
        let generation = cancellationGeneration
        let deadline = ProcessInfo.processInfo.systemUptime + maximumChainDuration
        var focus = FocusContext(initialProcessIdentifier: foregroundProcessIdentifier())
        for (index, action) in actions.enumerated() {
            onProgress?(ExecutionProgress(actionIndex: index + 1, actionCount: actions.count,
                                          kind: action.kind, phase: .running, completedActions: index))
            do {
                // Observers run synchronously and may cancel the chain. Never
                // perform this step's effects before checking their cancellation.
                try checkCancellation(generation, deadline: deadline)
                switch action.kind {
            case .window:
                try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
                try requireAccessibility(postingInput: false)
                try windowController.perform(action.windowOperation, expectedProcessIdentifier: focus.expectedProcessIdentifier) {
                    _ = try focus.validate(currentProcessIdentifier: self.foregroundProcessIdentifier())
                }
            case .keyboardShortcut:
                try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
                try requireAccessibility()
                try await postShortcut(keyCode: action.keyCode, modifiers: action.modifiers,
                                       focus: focus, generation: generation, deadline: deadline)
            case .insertText:
                try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
                try requireAccessibility()
                try await insertText(action.text, focus: focus, generation: generation, deadline: deadline)
            case .openURL:
                guard action.text.utf8.count <= 8_192,
                      let url = URL(string: action.text),
                      let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme),
                      scheme == "mailto" || !(url.host ?? "").isEmpty else {
                    throw RuntimeError.message("Only valid http, https, and mailto URLs can be opened. Scripts and file URLs are not accepted.")
                }
                guard NSWorkspace.shared.open(url) else { throw RuntimeError.message("macOS could not open the URL.") }
            case .launchApp:
                let launchedPID = try await launchApplication(action.text, generation: generation, deadline: deadline)
                try focus.acceptSuccessfulLaunch(processIdentifier: launchedPID,
                                                 currentProcessIdentifier: foregroundProcessIdentifier())
            case .delay:
                guard action.delaySeconds.isFinite, (0...60).contains(action.delaySeconds) else {
                    throw RuntimeError.message("Each delay must be between 0 and 60 seconds.")
                }
                try await pause(action.delaySeconds, generation: generation, deadline: deadline)
            case .menuCommand:
                // Menu titles are never logged; errors are fixed redacted strings.
                let path: MenuCommandPath
                do { path = try MenuCommandPath(parsing: action.text) }
                catch let error as MenuCommandPathError { throw RuntimeError.message(error.message) }
                let pid = try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
                try requireAccessibility(postingInput: false)
                try menuCommandController.perform(path: path, expectedProcessIdentifier: pid) {
                    try self.checkCancellation(generation, deadline: deadline)
                    _ = try focus.validate(currentProcessIdentifier: self.foregroundProcessIdentifier())
                }
            case .notification:
                try await notify(action.text, generation: generation, deadline: deadline)
            case .shellScript:
                guard allowScripts else { throw RuntimeError.message("Shell scripts are disabled. Enable them explicitly in Settings before running this action.") }
                guard !action.text.isEmpty, action.text.utf8.count <= 16_384, !action.text.contains("\0") else {
                    throw RuntimeError.message("A script must contain 1 to 16,384 UTF-8 bytes and no null characters.")
                }
                try await runScript(action.text, generation: generation, deadline: deadline)
                }
                try checkCancellation(generation, deadline: deadline)
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled || generation != cancellationGeneration
                onProgress?(ExecutionProgress(actionIndex: index + 1, actionCount: actions.count,
                                              kind: action.kind, phase: cancelled ? .cancelled : .failed,
                                              completedActions: index))
                throw error
            }
            onProgress?(ExecutionProgress(actionIndex: index + 1, actionCount: actions.count,
                                          kind: action.kind, phase: .completed, completedActions: index + 1))
        }
        return "Completed \(actions.count) action\(actions.count == 1 ? "" : "s")."
    }

    private func checkCancellation(_ generation: UInt64, deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard sessionAllowsExecution() else { throw RuntimeError.message("Automation stopped because the desktop session is locked, inactive or unavailable. Nothing will resume automatically from this chain.") }
        guard generation == cancellationGeneration else { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw RuntimeError.message("The action chain reached its 120-second time limit.")
        }
    }

    private func pause(_ seconds: TimeInterval, generation: UInt64, deadline: TimeInterval) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            try checkCancellation(generation, deadline: deadline)
            let remaining = min(0.05, end - ProcessInfo.processInfo.systemUptime)
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }
        try checkCancellation(generation, deadline: deadline)
    }

    private func launchApplication(_ bundleIdentifier: String, generation: UInt64,
                                   deadline: TimeInterval) async throws -> pid_t {
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 512,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw RuntimeError.message("The application bundle identifier is not installed.")
        }
        try checkCancellation(generation, deadline: deadline)
        let launchDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 10)
        let completion = CallbackResult<NSRunningApplication>()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            Task { @MainActor in
                if let error {
                    completion.value = .failure(error)
                } else if let application {
                    completion.value = .success(application)
                } else {
                    completion.value = .failure(RuntimeError.message("macOS did not return the launched application."))
                }
            }
        }
        // Launch Services has no public cancellation API. Cancellation prevents
        // all following actions but cannot undo an already accepted app launch.
        while true {
            try checkCancellation(generation, deadline: deadline)
            guard ProcessInfo.processInfo.systemUptime < launchDeadline else {
                throw RuntimeError.message("The application did not launch and become frontmost within 10 seconds. Following actions were not run.")
            }
            if let result = completion.value {
                let application = try result.get()
                guard !application.isTerminated, application.bundleIdentifier == bundleIdentifier else {
                    throw RuntimeError.message("The launched application terminated or did not match the requested bundle identifier.")
                }
                if foregroundProcessIdentifier() == application.processIdentifier {
                    return application.processIdentifier
                }
            }
            try await pause(0.025, generation: generation, deadline: deadline)
        }
    }

    private func requireAccessibility(postingInput: Bool = true) throws {
        guard AXIsProcessTrusted() else {
            throw RuntimeError.message("Accessibility permission is required for window and keyboard actions. Grant it in System Settings yourself.")
        }
        guard !postingInput || CGPreflightPostEventAccess() else {
            throw RuntimeError.message("macOS has not authorized this app to post input events.")
        }
    }

    private func postShortcut(keyCode: UInt16, modifiers: ModifierKeys, focus: FocusContext,
                              generation: UInt64, deadline: TimeInterval) async throws {
        guard keyCode <= 127, !modifiers.intersection([.command, .option, .control]).isEmpty else {
            throw RuntimeError.message("Shortcuts require a key code from 0 to 127 and Command, Option, or Control.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw RuntimeError.message("macOS could not create the keyboard event.")
        }
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: actionFlowEventMarker)
        }
        try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
        down.post(tap: .cghidEventTap)
        // Even cancellation must release the key. No synthetic modifier key-downs
        // are emitted, so a canceled chain cannot leave modifiers held.
        defer { up.post(tap: .cghidEventTap) }
        try await pause(0.015, generation: generation, deadline: deadline)
        try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
    }

    private func insertText(_ text: String, focus: FocusContext, generation: UInt64, deadline: TimeInterval) async throws {
        guard text.utf16.count <= 16_384 else { throw RuntimeError.message("Inserted text is limited to 16,384 UTF-16 units.") }
        // Capture only for this text action, after the caller checked AX access.
        // A shortcut in an earlier step may intentionally select another field.
        let pid = try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
        let elementGuard = try FocusedElementGuard {
            _ = try focus.validate(currentProcessIdentifier: self.foregroundProcessIdentifier())
            return try AXFocus.readFocusedElement(pid: pid)
        }
        // Unicode events leave the user's clipboard untouched. Some games,
        // terminals, secure fields, and applications ignore synthetic Unicode.
        // If the app cannot expose a stable AX identity, fail closed instead.
        for character in text {
            try checkCancellation(generation, deadline: deadline)
            try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
            try elementGuard.validate()
            let units = Array(String(character).utf16)
            guard units.count <= 256,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw RuntimeError.message("A text character is too large or macOS could not create its input event.")
            }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: actionFlowEventMarker)
            }
            do {
                try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
                try elementGuard.validate()
                try checkCancellation(generation, deadline: deadline)
                down.post(tap: .cghidEventTap)
                // Never suppress key-up, including when AX focus becomes
                // unavailable or changes while the key is down.
                defer { up.post(tap: .cghidEventTap) }
                try await pause(ActionPreflight.textCharacterPauseSeconds, generation: generation, deadline: deadline)
                try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
                try elementGuard.validate()
            }
            try await pause(ActionPreflight.textCharacterPauseSeconds, generation: generation, deadline: deadline)
            try focus.validate(currentProcessIdentifier: foregroundProcessIdentifier())
            try elementGuard.validate()
        }
    }

    private func notify(_ text: String, generation: UInt64, deadline: TimeInterval) async throws {
        guard !text.isEmpty, text.utf8.count <= 4_096 else {
            throw RuntimeError.message("Notification text must contain 1 to 4,096 UTF-8 bytes.")
        }
        // Never request authorization from an action. Delivery is unavailable
        // until the user grants notification permission outside this executor.
        let center = UNUserNotificationCenter.current()
        let settingsResult = CallbackResult<UNAuthorizationStatus>()
        center.getNotificationSettings { settings in
            Task { @MainActor in settingsResult.value = .success(settings.authorizationStatus) }
        }
        let authorization = try await notificationResult(settingsResult, generation: generation, deadline: deadline)
        guard authorization == .authorized || authorization == .provisional else {
            throw RuntimeError.message("Notifications are not authorized. This action does not request permission automatically.")
        }
        let content = UNMutableNotificationContent()
        content.title = "ActionFlow"
        content.body = text
        let identifier = "ActionFlow.action.\(UUID().uuidString)"
        let delivery = CallbackResult<Bool>()
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            Task { @MainActor in
                delivery.value = error.map { .failure($0) } ?? .success(true)
            }
        }
        do {
            _ = try await notificationResult(delivery, generation: generation, deadline: deadline)
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            throw error
        }
    }

    private func notificationResult<Value>(_ result: CallbackResult<Value>, generation: UInt64,
                                           deadline: TimeInterval) async throws -> Value {
        let callbackDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 5)
        while true {
            try checkCancellation(generation, deadline: deadline)
            if let value = result.value { return try value.get() }
            guard ProcessInfo.processInfo.systemUptime < callbackDeadline else {
                throw RuntimeError.message("The notification service did not respond within 5 seconds.")
            }
            try await pause(0.025, generation: generation, deadline: deadline)
        }
    }

    private func runScript(_ script: String, generation: UInt64, deadline: TimeInterval) async throws {
        // Spawn a new process group, discard output rather than accumulating it,
        // and pass a small environment rather than application credentials.
        let process = try BoundedScript(script: script)
        defer { process.terminateGroup() }
        let scriptDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 10)
        while true {
            try checkCancellation(generation, deadline: deadline)
            guard ProcessInfo.processInfo.systemUptime < scriptDeadline else {
                throw RuntimeError.message("The shell script reached its 10-second time limit. Its process group was terminated.")
            }
            if let status = try process.poll() {
                guard status == 0 else { throw RuntimeError.message("The shell script exited unsuccessfully, wait status \(status). Output is discarded.") }
                return
            }
            try await pause(0.05, generation: generation, deadline: deadline)
        }
    }
}

@MainActor
private final class CallbackResult<Value> {
    var value: Result<Value, Error>?
}

enum RuntimeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// A timeout is not a sandbox. Opted-in scripts run with the user's authority;
/// a script can deliberately escape its process group or launch other services.
@MainActor
private final class BoundedScript {
    private let pid: pid_t
    private var reaped = false

    init(script: String) throws {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw RuntimeError.message("Could not initialize script process attributes.") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw RuntimeError.message("Could not initialize script file actions.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw RuntimeError.message("Could not isolate the script process group.")
        }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0 else {
                throw RuntimeError.message("Could not redirect script input and output.")
            }
        }
        let argumentStrings: [String] = ["/bin/zsh", "-f", "-c", script]
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())", "LANG=en_US.UTF-8"]
        let arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { string in
            string.withCString { strdup($0) }
        }
        let environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { string in
            string.withCString { strdup($0) }
        }
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
            throw RuntimeError.message("Could not allocate the script process arguments.")
        }
        var argv = arguments + [nil]
        var envp = environment + [nil]
        var child: pid_t = 0
        let result = posix_spawn(&child, "/bin/zsh", &actions, &attributes, &argv, &envp)
        guard result == 0 else { throw RuntimeError.message("Could not start the shell script, POSIX error \(result).") }
        pid = child
    }

    func poll() throws -> Int32? {
        guard !reaped else { return 0 }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 { return nil }
        if result == pid { reaped = true; return status }
        if errno == EINTR { return nil }
        throw RuntimeError.message("Could not read the shell script's exit status, POSIX error \(errno).")
    }

    func terminateGroup() {
        // Kill descendants even if the shell has already exited. Only the group
        // created by this executor is targeted, never a user application.
        kill(-pid, SIGKILL)
        guard !reaped else { return }
        let child = pid
        reaped = true
        // Reaping is the only blocking wait and runs outside the main actor.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        }
    }
}
