import Foundation

/// Only process identity and a bundle identifier, never window titles or typed text.
public struct ExecutionContext: Equatable, Sendable {
    public var processIdentifier: Int32?
    public var bundleIdentifier: String
    public init(processIdentifier: Int32?, bundleIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    public func isSameTarget(as other: ExecutionContext) -> Bool {
        guard let pid = processIdentifier, pid > 0 else { return false }
        return pid == other.processIdentifier && bundleIdentifier == other.bundleIdentifier && !bundleIdentifier.isEmpty
    }
}

public struct TriggerSignal: Sendable {
    public var kind: TriggerKind
    public var keyCode: UInt16
    public var modifiers: ModifierKeys
    public var mouseButton: Int
    public var scrollDirection: ScrollDirection
    public var appBundleIdentifier: String
    public init(kind: TriggerKind, keyCode: UInt16 = 0, modifiers: ModifierKeys = [], mouseButton: Int = 0,
                scrollDirection: ScrollDirection = .up, appBundleIdentifier: String = "") {
        self.kind = kind; self.keyCode = keyCode; self.modifiers = modifiers
        self.mouseButton = mouseButton; self.scrollDirection = scrollDirection
        self.appBundleIdentifier = appBundleIdentifier
    }
}

/// Pure, injectable monotonic-time scheduler. It never reads the desktop or runs actions.
public struct RuleScheduler: Sendable {
    public static let doubleShortcutWindow: TimeInterval = 0.35
    private struct PendingDoubleShortcut: Sendable {
        var time: TimeInterval
        var context: ExecutionContext
        var trigger: Trigger
    }
    private var lastFired: [UUID: TimeInterval] = [:]
    private var pendingDoubleShortcuts: [UUID: PendingDoubleShortcut] = [:]
    public init() {}
    public mutating func reset() {
        lastFired.removeAll()
        invalidatePendingShortcuts()
    }
    /// Call on every observed app activation, including apps excluded from automatic execution.
    /// Keep existing cooldowns and interval schedules intact.
    public mutating func invalidatePendingShortcuts() { pendingDoubleShortcuts.removeAll() }
    public mutating func removeStaleRules(_ rules: [AutomationRule]) {
        let ids = Set(rules.map(\.id))
        lastFired = lastFired.filter { ids.contains($0.key) }
        let activeDoubleTriggers = Dictionary(rules.filter { $0.enabled && $0.trigger.kind == .doubleShortcut }
            .map { ($0.id, $0.trigger) }, uniquingKeysWith: { first, _ in first })
        pendingDoubleShortcuts = pendingDoubleShortcuts.filter { activeDoubleTriggers[$0.key] == $0.value.trigger }
    }
    private mutating func prepareDoubleShortcuts(rules: [AutomationRule], context: ExecutionContext, now: TimeInterval) {
        removeStaleRules(rules)
        pendingDoubleShortcuts = pendingDoubleShortcuts.filter {
            $0.value.context.isSameTarget(as: context) && now >= $0.value.time &&
                now <= $0.value.time + Self.doubleShortcutWindow
        }
    }
    public static func canAutomaticallyRun(context: ExecutionContext, editorBundleIdentifier: String,
                                           automationEnabled: Bool, isRecording: Bool, isPreparingManualRun: Bool) -> Bool {
        automationEnabled && !isRecording && !isPreparingManualRun && context.processIdentifier.map { $0 > 0 } == true &&
        !context.bundleIdentifier.isEmpty && context.bundleIdentifier != editorBundleIdentifier.lowercased()
    }
    public mutating func candidates(for signal: TriggerSignal, rules: [AutomationRule], context: ExecutionContext,
                                    now: TimeInterval) -> [AutomationRule] {
        guard now.isFinite else { pendingDoubleShortcuts.removeAll(); return [] }
        prepareDoubleShortcuts(rules: rules, context: context, now: now)
        // Input decoders emit physical shortcut presses, never a pre-completed double shortcut.
        guard signal.kind != .interval, signal.kind != .doubleShortcut else { return [] }
        var output: [AutomationRule] = []
        for rule in rules where rule.enabled {
            let trigger = rule.trigger
            let matches: Bool
            if trigger.kind == .doubleShortcut {
                guard rule.conditions.matches(bundleIdentifier: context.bundleIdentifier) else {
                    pendingDoubleShortcuts.removeValue(forKey: rule.id)
                    continue
                }
                // Mouse and scroll events do not break a pair; another shortcut chord does.
                guard signal.kind == .shortcut else { continue }
                guard trigger.keyCode == signal.keyCode && trigger.modifiers == signal.modifiers,
                      context.isSameTarget(as: context) else {
                    pendingDoubleShortcuts.removeValue(forKey: rule.id)
                    continue
                }
                if pendingDoubleShortcuts.removeValue(forKey: rule.id) != nil {
                    matches = true
                } else {
                    pendingDoubleShortcuts[rule.id] = PendingDoubleShortcut(time: now, context: context, trigger: trigger)
                    continue
                }
            } else {
                guard trigger.kind == signal.kind,
                      rule.conditions.matches(bundleIdentifier: context.bundleIdentifier) else { continue }
                switch signal.kind {
                case .shortcut: matches = trigger.keyCode == signal.keyCode && trigger.modifiers == signal.modifiers
                case .mouseButton: matches = trigger.mouseButton == signal.mouseButton && trigger.modifiers == signal.modifiers
                case .scroll: matches = trigger.scrollDirection == signal.scrollDirection && trigger.modifiers == signal.modifiers
                case .appActivated:
                    let target = trigger.appBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let source = signal.appBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    matches = target == source && source == context.bundleIdentifier
                case .appLaunched, .appTerminated:
                    // Event identity is independent of the current frontmost execution target.
                    let target = RuleConditions.normalized(trigger.appBundleIdentifier)
                    let source = RuleConditions.normalized(signal.appBundleIdentifier)
                    matches = !source.isEmpty && target == source
                case .interval, .doubleShortcut: matches = false
                }
            }
            // A complete pair is consumed even during cooldown. No overlapping pairs or replay.
            let cooldown = max(0.25, rule.cooldown)
            guard matches, cooldown.isFinite, now - (lastFired[rule.id] ?? -.greatestFiniteMagnitude) >= cooldown else { continue }
            lastFired[rule.id] = now; output.append(rule)
        }
        return output
    }
    public mutating func intervalCandidates(rules: [AutomationRule], context: ExecutionContext, now: TimeInterval) -> [AutomationRule] {
        guard now.isFinite else { pendingDoubleShortcuts.removeAll(); return [] }
        prepareDoubleShortcuts(rules: rules, context: context, now: now)
        var output: [AutomationRule] = []
        for rule in rules where rule.enabled && rule.trigger.kind == .interval {
            guard rule.trigger.intervalSeconds.isFinite, rule.cooldown.isFinite else { continue }
            guard rule.conditions.matches(bundleIdentifier: context.bundleIdentifier) else { continue }
            guard let last = lastFired[rule.id] else { lastFired[rule.id] = now; continue }
            let interval = max(1, rule.trigger.intervalSeconds, rule.cooldown)
            // Sleep wakes produce at most one run, never a replay storm.
            guard now - last >= interval else { continue }
            lastFired[rule.id] = now; output.append(rule)
        }
        return output
    }
}

/// Bounded FIFO with de-duplication and fail-closed target identity on dequeue.
public struct RuleExecutionQueue: Sendable {
    private struct Pending: Sendable { var id: UUID; var context: ExecutionContext }
    private var entries: [Pending] = []
    public let capacity: Int
    public var count: Int { entries.count }
    public init(capacity: Int = 32) { self.capacity = max(1, min(256, capacity)) }
    public mutating func clear() { entries.removeAll() }
    @discardableResult
    public mutating func append(_ rule: AutomationRule, context: ExecutionContext, runningRuleID: UUID?) -> Bool {
        guard entries.count < capacity, runningRuleID != rule.id, !entries.contains(where: { $0.id == rule.id }) else { return false }
        entries.append(Pending(id: rule.id, context: context)); return true
    }
    public mutating func next(rules: [AutomationRule], context: ExecutionContext) -> AutomationRule? {
        while !entries.isEmpty {
            let entry = entries.removeFirst()
            guard entry.context.isSameTarget(as: context),
                  let rule = rules.first(where: { $0.id == entry.id }), rule.enabled,
                  rule.conditions.matches(bundleIdentifier: context.bundleIdentifier) else { continue }
            return rule
        }
        return nil
    }
}
