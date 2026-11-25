import AppKit
import ActionFlowCore

/// Owns the action executor and everything about running, queueing and cancelling rule chains.
/// State the UI shows (`isExecuting`, progress, activity entries) is reported through closures;
/// everything it needs to know about the model is asked for through closures. All closures are
/// wired once by the owner and default to inert values.
@MainActor
final class RuleExecutionCoordinator {
    // MARK: Asked from the owner
    var rules: () -> [AutomationRule] = { [] }
    var hasConfigurationLease: () -> Bool = { false }
    /// The in-memory `configuration.allowScripts`.
    var allowsScripts: () -> Bool = { false }
    /// Capabilities a manual (non-automatic) run of the rule still lacks.
    var missingCapabilities: (AutomationRule) -> [AutomationCapability] = { _ in [] }
    var isEligibleForAutomaticExecution: (ExecutionContext) -> Bool = { _ in false }
    /// The currently published progress value.
    var currentProgress: () -> ExecutionProgress? = { nil }

    // MARK: Reported to the owner
    var publishExecuting: (Bool) -> Void = { _ in }
    var publishProgress: (ExecutionProgress?) -> Void = { _ in }
    /// Rule name, message, success, progress.
    var recordActivity: (String, String, Bool, ExecutionProgress?) -> Void = { _, _, _, _ in }
    /// `isPreparingManualRun` just changed (the keyboard interceptor's snapshot depends on it).
    var onPreparationChanged: () -> Void = {}

    private let executor = ActionExecutor()
    private var runningTask: Task<Void, Never>?
    private var busyRuleID: UUID?
    private var pendingRules = RuleExecutionQueue()
    private var manualActivationTask: Task<Void, Never>? {
        didSet { onPreparationChanged() }
    }
    private var manualActivationID: UUID?

    var allowScripts: Bool {
        get { executor.allowScripts }
        set { executor.allowScripts = newValue }
    }
    var isPreparingManualRun: Bool { manualActivationTask != nil }
    /// True while a chain runs, a manual run is being prepared or rules are queued.
    var hasActiveWork: Bool { runningTask != nil || manualActivationTask != nil || pendingRules.count > 0 }

    static var currentContext: ExecutionContext {
        let app = NSWorkspace.shared.frontmostApplication
        return ExecutionContext(processIdentifier: app?.processIdentifier, bundleIdentifier: app?.bundleIdentifier ?? "")
    }

    /// Waits for `target` to become frontmost (the caller already asked it to activate), then runs the rule.
    func beginManualRun(_ rule: AutomationRule, target: NSRunningApplication) {
        let activationID = UUID()
        manualActivationID = activationID
        publishExecuting(true)
        manualActivationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.manualActivationID == activationID {
                    self.manualActivationTask = nil; self.manualActivationID = nil
                    if self.runningTask == nil { self.publishExecuting(false) }
                }
            }
            for _ in 0..<40 {
                guard !Task.isCancelled, self.manualActivationID == activationID else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { self.execute(rule); return }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            self.recordActivity(rule.name, AppLocalization.text("The target did not become active within two seconds. No actions were run."), false, nil)
        }
    }

    func enqueue(_ rule: AutomationRule, context: ExecutionContext) {
        guard isEligibleForAutomaticExecution(context), busyRuleID != rule.id else { return }
        if runningTask == nil { execute(rule) }
        else { pendingRules.append(rule, context: context, runningRuleID: busyRuleID) }
    }

    func stop() {
        manualActivationTask?.cancel()
        manualActivationTask = nil
        manualActivationID = nil
        if runningTask == nil { publishExecuting(false) }
        pendingRules.clear()
        executor.cancel()
        runningTask?.cancel()
    }

    private func execute(_ rule: AutomationRule) {
        guard hasConfigurationLease() else { return }
        let errors = RuleValidator.validate(rule)
        guard errors.isEmpty else { recordActivity(rule.name, errors.map { AppLocalization.validationMessage($0) }.joined(separator: " "), false, nil); return }
        let missing = missingCapabilities(rule)
        guard missing.isEmpty else { recordActivity(rule.name, AppLocalization.format("Skipped: missing %@. No actions were run.", missing.map { AppLocalization.text($0.title) }.joined(separator: ", ")), false, nil); return }
        guard runningTask == nil else { recordActivity(rule.name, AppLocalization.text("Skipped: another action chain is running."), false, nil); return }
        executor.allowScripts = allowsScripts()
        publishProgress(nil)
        executor.onProgress = { [weak self] progress in self?.publishProgress(progress) }
        busyRuleID = rule.id
        publishExecuting(true)
        runningTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.runningTask = nil; self.publishExecuting(false); self.busyRuleID = nil
                self.executor.onProgress = nil
                self.publishProgress(nil)
                self.runNextPending()
            }
            do {
                let result = try await self.executor.execute(rule.actions)
                self.recordActivity(rule.name, result, true, self.currentProgress())
            } catch {
                self.recordActivity(rule.name, AppLocalization.describe(error), false, self.currentProgress())
            }
        }
    }

    private func runNextPending() {
        let context = Self.currentContext
        guard isEligibleForAutomaticExecution(context) else { pendingRules.clear(); return }
        if let next = pendingRules.next(rules: rules(), context: context) { execute(next) }
    }
}
