import Foundation
import ActionFlowCore

/// Owns the input monitor, the rule scheduler and the cached trigger interest, and turns one
/// observed input event into scheduler candidates plus the key-consume decision.
@MainActor
final class TriggerRouter {
    /// The outcome of routing one event.
    struct Routed {
        /// True when the key press belongs to an enabled single-press shortcut rule that keeps it from the active app.
        var consumes: Bool
        /// Rules the scheduler wants to run now, in order. Empty when the event was ignored or a repeat.
        var candidates: [AutomationRule]
        /// The execution context the candidates were selected for.
        var context: ExecutionContext

        static var ignored: Routed {
            Routed(consumes: false, candidates: [], context: ExecutionContext(processIdentifier: nil, bundleIdentifier: ""))
        }
    }

    private let monitor = InputMonitor()
    private var scheduler = RuleScheduler()
    /// The input kinds the enabled rules currently need.
    private(set) var interest: TriggerInterest = []

    /// Returns true to keep the key press from the active app (answered synchronously).
    var onEvent: ((InputEvent) -> Bool)? {
        get { monitor.onEvent }
        set { monitor.onEvent = newValue }
    }
    var onStatus: ((String) -> Void)? {
        get { monitor.onStatus }
        set { monitor.onStatus = newValue }
    }
    var running: Bool { monitor.running }
    var interceptsShortcuts: Bool { monitor.interceptsShortcuts }

    /// Recomputes the interest from `rules`. Returns true when it changed.
    @discardableResult
    func refreshInterest(rules: [AutomationRule]) -> Bool {
        let updated = TriggerInterest(rules: rules)
        guard updated != interest else { return false }
        interest = updated
        return true
    }

    /// Starts (or reconfigures) the monitor when `canRun` and some rule needs input; stops it otherwise.
    func reconfigure(canRun: Bool) {
        if canRun && interest.needsInputMonitoring {
            // No-op when already running with the same input interest; recreates the tap otherwise.
            monitor.start(interest: interest)
        } else { monitor.stop() }
    }

    func stopMonitor() { monitor.stop() }
    func reset() { scheduler.reset() }
    func invalidatePendingShortcuts() { scheduler.invalidatePendingShortcuts() }
    func removeStaleRules(_ rules: [AutomationRule]) { scheduler.removeStaleRules(rules) }

    /// Never consumes unless the input is eligible for automatic execution, so pausing automation,
    /// focusing ActionFlow, recording a shortcut or a locked session always lets keys through.
    func route(_ event: InputEvent, rules: [AutomationRule], currentContext: () -> ExecutionContext,
               isEligible: (ExecutionContext) -> Bool) -> Routed {
        // Skip the scheduler pass for input no enabled rule can match. Mouse and scroll never affect a
        // pending double-shortcut pair, and app activation invalidates pairs in the workspace observer.
        guard interest.wants(event.kind) else { return .ignored }
        let context = currentContext()
        guard isEligible(context) else { return .ignored }
        let isLifecycle = event.kind == .appLaunched || event.kind == .appTerminated
        if !isLifecycle && !event.appBundleIdentifier.isEmpty && event.appBundleIdentifier.lowercased() != context.bundleIdentifier { return .ignored }
        // Independent of cooldown and running state, so holding an owned chord never leaks repeats.
        let consumes = event.kind == .shortcut && ShortcutInterception.consumes(keyCode: event.keyCode, modifiers: event.modifiers,
            rules: rules, bundleIdentifier: context.bundleIdentifier)
        // Auto-repeat never triggers a rule or affects a pending double press.
        if event.isRepeat { return Routed(consumes: consumes, candidates: [], context: context) }
        let signal = TriggerSignal(kind: event.kind, keyCode: event.keyCode, modifiers: event.modifiers,
            mouseButton: event.mouseButton, scrollDirection: event.scrollDirection, appBundleIdentifier: event.appBundleIdentifier)
        let candidates = scheduler.candidates(for: signal, rules: rules, context: context, now: ProcessInfo.processInfo.systemUptime)
        return Routed(consumes: consumes, candidates: candidates, context: context)
    }

    func intervalCandidates(rules: [AutomationRule], context: ExecutionContext) -> [AutomationRule] {
        scheduler.intervalCandidates(rules: rules, context: context, now: ProcessInfo.processInfo.systemUptime)
    }
}
