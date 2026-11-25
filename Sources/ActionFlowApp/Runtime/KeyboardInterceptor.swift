import ApplicationServices
import Foundation
import ActionFlowCore

/// Everything the consume decision for one key press needs, captured on the main actor and handed to the
/// keyboard tap thread. Pure data.
///
/// A stale snapshot can only make a consume decision lag a state change by one main-thread turn (the
/// owner pushes a fresh snapshot whenever an input changes and once per second as a safety net). Every
/// default points the safe way: `blocked` consumes nothing, and a snapshot that is not provably eligible
/// lets the key press through.
struct InterceptionSnapshot: Sendable, Equatable {
    var index: ShortcutInterceptionIndex
    /// Lease && session safety && automation enabled && not recording && not preparing a manual run.
    var automaticExecutionAllowed: Bool
    /// Lowercased bundle identifier of ActionFlow itself; key presses in ActionFlow are never consumed.
    var editorBundleIdentifier: String
    var frontmostProcessIdentifier: Int32?
    /// Lowercased and trimmed, like `ExecutionContext`.
    var frontmostBundleIdentifier: String

    init(index: ShortcutInterceptionIndex, automaticExecutionAllowed: Bool, editorBundleIdentifier: String,
         frontmostProcessIdentifier: Int32?, frontmostBundleIdentifier: String) {
        self.index = index
        self.automaticExecutionAllowed = automaticExecutionAllowed
        self.editorBundleIdentifier = editorBundleIdentifier.lowercased()
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.frontmostBundleIdentifier = frontmostBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Consumes nothing.
    static let blocked = InterceptionSnapshot(index: .empty, automaticExecutionAllowed: false, editorBundleIdentifier: "",
                                              frontmostProcessIdentifier: nil, frontmostBundleIdentifier: "")

    /// The single definition of "this input may run rules automatically", shared by `consumes` and
    /// `AppModel.eligibleForAutomaticExecution`. `automaticExecutionAllowed` already folds in the
    /// automation switch, recording, manual-run preparation, the lease and session safety.
    static func isEligible(context: ExecutionContext, editorBundleIdentifier: String, automaticExecutionAllowed: Bool) -> Bool {
        RuleScheduler.canAutomaticallyRun(context: context, editorBundleIdentifier: editorBundleIdentifier,
                                          automationEnabled: automaticExecutionAllowed, isRecording: false, isPreparingManualRun: false)
    }

    /// True when this key press belongs to an enabled single-press shortcut rule that keeps it from the
    /// frontmost app named by this snapshot. Callable from any thread.
    func consumes(keyCode: UInt16, modifiers: ModifierKeys) -> Bool {
        guard automaticExecutionAllowed, !index.isEmpty else { return false }
        let context = ExecutionContext(processIdentifier: frontmostProcessIdentifier, bundleIdentifier: frontmostBundleIdentifier)
        guard Self.isEligible(context: context, editorBundleIdentifier: editorBundleIdentifier,
                              automaticExecutionAllowed: automaticExecutionAllowed) else { return false }
        return index.consumes(keyCode: keyCode, modifiers: modifiers, bundleIdentifier: context.bundleIdentifier)
    }
}

/// A key press the interceptor already decided on, handed to the main actor for scheduling.
struct InterceptedKey: Sendable {
    var keyCode: UInt16
    var modifiers: ModifierKeys
    var isRepeat: Bool
    /// Frontmost bundle identifier from the snapshot the decision used.
    var bundleIdentifier: String
    /// The interceptor run that produced it; lets the owner drop deliveries that outlive a restart.
    var generation: Int
}

/// State shared with the tap callback. Retained through `Unmanaged` as the tap's `userInfo` and released
/// only after the tap is invalidated and the thread has exited.
fileprivate final class KeyboardInterceptorContext: @unchecked Sendable {
    let owner: KeyboardInterceptor
    let generation: Int
    let onKey: @Sendable (InterceptedKey) -> Void
    let onDisabled: @Sendable (Int) -> Void
    /// Assigned once, on the starting thread, before the interceptor thread exists.
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    private let lock = NSLock()
    private var runLoopStorage: CFRunLoop?
    private var stopStorage = false

    init(owner: KeyboardInterceptor, generation: Int, onKey: @escaping @Sendable (InterceptedKey) -> Void,
         onDisabled: @escaping @Sendable (Int) -> Void) {
        self.owner = owner
        self.generation = generation
        self.onKey = onKey
        self.onDisabled = onDisabled
    }

    var runLoop: CFRunLoop? {
        get { lock.lock(); defer { lock.unlock() }; return runLoopStorage }
        set { lock.lock(); runLoopStorage = newValue; lock.unlock() }
    }
    var stopRequested: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stopStorage }
        set { lock.lock(); stopStorage = newValue; lock.unlock() }
    }
}

/// The active (event-dropping) keyboard tap on a dedicated thread with its own run loop, so a busy main
/// thread can never delay key delivery system-wide. The callback never waits for the main actor: it decodes
/// the key press, decides from the latest `InterceptionSnapshot`, hands the decoded key to `onKey` and
/// returns. Not `@MainActor`; every mutable member is behind `lock`.
///
/// Threads: `start` and `stop` run on the caller's thread (the main actor in practice); the tap is created
/// there. The source is attached, the tap enabled and the run loop run on the interceptor thread; the
/// callback, `onKey` and `onDisabled` run on that thread. `update` may be called from any thread.
final class KeyboardInterceptor: @unchecked Sendable {
    private struct Run {
        var context: KeyboardInterceptorContext
        var pointer: UnsafeMutableRawPointer
        var finished: DispatchSemaphore
    }

    private static let maximumTimeoutReenables = 3
    private static let timeoutReenableWindow: TimeInterval = 60

    private let lock = NSLock()
    private var snapshot = InterceptionSnapshot.blocked
    private var run: Run?
    private var generationStorage = 0
    /// Uptimes of recent in-place re-enables after a timeout. Kept across stop() so the limit is a rolling window.
    private var timeoutReenables: [TimeInterval] = []

    init() {}

    deinit { stop() }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return run != nil }
    /// Identifies the current (or most recent) run; 0 before the first start.
    var generation: Int { lock.lock(); defer { lock.unlock() }; return generationStorage }

    /// Replaces the snapshot later key presses are decided with. Cheap; callable from any thread, running or not.
    func update(_ newSnapshot: InterceptionSnapshot) {
        lock.lock()
        snapshot = newSnapshot
        lock.unlock()
    }

    /// Creates the active tap and runs it on a new thread. Returns false (nothing left running) when macOS
    /// refuses the tap. Never requests or prompts for permissions. `onKey` and `onDisabled` are invoked on
    /// the interceptor thread and must not block.
    func start(onKey: @escaping @Sendable (InterceptedKey) -> Void, onDisabled: @escaping @Sendable (Int) -> Void) -> Bool {
        lock.lock()
        if run != nil { lock.unlock(); return true }
        generationStorage += 1
        let generation = generationStorage
        lock.unlock()

        let context = KeyboardInterceptorContext(owner: self, generation: generation, onKey: onKey, onDisabled: onDisabled)
        let pointer = Unmanaged.passRetained(context).toOpaque()
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: actionFlowKeyboardInterceptCallback,
                                          userInfo: pointer) else {
            Unmanaged<KeyboardInterceptorContext>.fromOpaque(pointer).release()
            return false
        }
        // Held until the interceptor thread has attached the source, so no key press is decided too early.
        CGEvent.tapEnable(tap: tap, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            Unmanaged<KeyboardInterceptorContext>.fromOpaque(pointer).release()
            return false
        }
        context.tap = tap
        context.source = source

        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            context.runLoop = loop
            CFRunLoopAddSource(loop, source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            // CFRunLoopStop can arrive before the loop runs (it is then a no-op), so the stop flag is the
            // truth and the finite timeout is only a safety net; stop() also repeats CFRunLoopStop.
            while !context.stopRequested {
                let result = CFRunLoopRunInMode(.defaultMode, 1, false)
                if result == .finished { break }
            }
            CFRunLoopRemoveSource(loop, source, .defaultMode)
            finished.signal()
        }
        thread.name = "ActionFlow.KeyboardInterceptor"
        thread.qualityOfService = .userInteractive
        lock.lock()
        run = Run(context: context, pointer: pointer, finished: finished)
        lock.unlock()
        thread.start()
        ready.wait()
        return true
    }

    /// Synchronous: when it returns the tap is gone, the thread has exited and no callback can run again.
    func stop() {
        lock.lock()
        let current = run
        run = nil
        snapshot = .blocked
        lock.unlock()
        guard let current else { return }
        let context = current.context
        context.stopRequested = true
        if let tap = context.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        var attempts = 0
        while current.finished.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if let loop = context.runLoop {
                CFRunLoopStop(loop)
                CFRunLoopWakeUp(loop)
            }
            attempts += 1
            // The thread never blocks outside the run loop. If it still has not exited, keep the context
            // alive (leak it) rather than free memory a callback might touch.
            if attempts > 250 { return }
        }
        Unmanaged<KeyboardInterceptorContext>.fromOpaque(current.pointer).release()
    }

    // MARK: Tap thread

    /// Runs on the interceptor thread. Returns true to drop the key press.
    fileprivate func handle(_ type: CGEventType, event: CGEvent, context: KeyboardInterceptorContext) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout && reenableAfterTimeout(context) { return false }
            if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: false) }
            context.onDisabled(context.generation)
            return false
        }
        guard type == .keyDown, !context.stopRequested, let key = InputDecoder.decodeKey(event: event) else { return false }
        lock.lock()
        let decided = snapshot
        lock.unlock()
        let drop = decided.consumes(keyCode: key.keyCode, modifiers: key.modifiers)
        context.onKey(InterceptedKey(keyCode: key.keyCode, modifiers: key.modifiers, isRepeat: key.isRepeat,
                                     bundleIdentifier: decided.frontmostBundleIdentifier, generation: context.generation))
        return drop
    }

    /// A slow system can still time the tap out. Re-enable in place a few times so owned shortcuts do not
    /// leak; beyond the limit the caller disables the tap and reports instead.
    private func reenableAfterTimeout(_ context: KeyboardInterceptorContext) -> Bool {
        guard let tap = context.tap else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        timeoutReenables = timeoutReenables.filter { now - $0 < Self.timeoutReenableWindow }
        let allowed = timeoutReenables.count < Self.maximumTimeoutReenables
        if allowed { timeoutReenables.append(now) }
        lock.unlock()
        if allowed { CGEvent.tapEnable(tap: tap, enable: true) }
        return allowed
    }
}

private func actionFlowKeyboardInterceptCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                                 _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<KeyboardInterceptorContext>.fromOpaque(userInfo).takeUnretainedValue()
    // Only key presses of an owned shortcut are dropped. Tap-disabled notices and everything else pass through.
    if context.owner.handle(type, event: event, context: context) { return nil }
    return Unmanaged.passUnretained(event)
}
