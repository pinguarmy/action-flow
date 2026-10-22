import Foundation

public enum RuleValidator {
    public static let maximumRules = 1_000
    public static let maximumActionsPerRule = 64
    public static let maximumTextBytes = 65_536
    public static let maximumConditionApps = 256
    public static let maximumDelaySeconds: Double = 60
    public static let minimumIntervalSeconds: Double = 1
    public static let maximumIntervalSeconds: Double = 86_400

    /// Reports content errors even for disabled rules so editors can explain what is missing.
    public static func validate(_ rule: AutomationRule) -> [String] {
        var errors = structuralErrors(rule)
        if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Give this rule a name.")
        }
        if !rule.cooldown.isFinite || !(0...86_400).contains(rule.cooldown) {
            errors.append("Cooldown must be between 0 and 86400 seconds.")
        }
        validateTrigger(rule.trigger, errors: &errors)
        errors.append(contentsOf: ActionPreflight.errors(for: rule.actions))
        for identifier in rule.conditions.appBundleIdentifiers + rule.conditions.excludedAppBundleIdentifiers {
            if !validBundleIdentifier(identifier) {
                errors.append("App conditions must use bundle identifiers, such as com.apple.Safari.")
                break
            }
        }
        let included = Set(rule.conditions.appBundleIdentifiers.map(RuleConditions.normalized))
        let excluded = Set(rule.conditions.excludedAppBundleIdentifiers.map(RuleConditions.normalized))
        if !included.isEmpty && included.isSubset(of: excluded) {
            errors.append("App exclusions prevent this rule from running in every included app.")
        }
        if rule.trigger.kind == .appActivated,
           !rule.conditions.matches(bundleIdentifier: rule.trigger.appBundleIdentifier) {
            errors.append("App conditions exclude the app activation trigger.")
        }
        return Array(NSOrderedSet(array: errors)) as? [String] ?? errors
    }

    /// Only enabled rules can collide. App allow/deny conditions are considered before warning.
    public static func conflicts(in rules: [AutomationRule]) -> [String] {
        let enabled = rules.filter(\.enabled)
        var messages: [String] = []
        for firstIndex in enabled.indices {
            for secondIndex in enabled.indices where secondIndex > firstIndex {
                let first = enabled[firstIndex]
                let second = enabled[secondIndex]
                if sameTrigger(first.trigger, second.trigger), conditionsOverlap(first, second) {
                    messages.append("\"\(first.name)\" and \"\(second.name)\" share \(first.trigger.summary) in overlapping apps.")
                }
            }
        }
        return messages
    }

    /// These limits apply to disabled drafts as well as active rules.
    static func structuralErrors(_ rule: AutomationRule) -> [String] {
        var errors: [String] = []
        if rule.name.utf8.count > 256 { errors.append("Rule names cannot exceed 256 bytes.") }
        if rule.group.utf8.count > 256 { errors.append("Group names cannot exceed 256 bytes.") }
        if rule.actions.count > maximumActionsPerRule { errors.append("A rule cannot have more than 64 actions.") }
        if Set(rule.actions.map(\.id)).count != rule.actions.count {
            errors.append("Action identifiers must be unique within a rule.")
        }
        if rule.conditions.appBundleIdentifiers.count > maximumConditionApps ||
            rule.conditions.excludedAppBundleIdentifiers.count > maximumConditionApps {
            errors.append("An app condition list cannot have more than 256 entries.")
        }
        let identifiers = rule.conditions.appBundleIdentifiers + rule.conditions.excludedAppBundleIdentifiers + [rule.trigger.appBundleIdentifier]
        if identifiers.contains(where: { $0.utf8.count > 255 }) {
            errors.append("App bundle identifiers cannot exceed 255 bytes.")
        }
        if !rule.cooldown.isFinite || !rule.trigger.intervalSeconds.isFinite ||
            rule.actions.contains(where: { !$0.delaySeconds.isFinite }) {
            errors.append("Timing values must be finite numbers.")
        }
        for action in rule.actions {
            if action.text.utf8.count > maximumTextBytes {
                errors.append("Action text cannot exceed 65536 bytes.")
                break
            }
            if action.text.contains("\0") {
                errors.append("Action text cannot contain NUL characters.")
                break
            }
        }
        return errors
    }

    private static func validateTrigger(_ trigger: Trigger, errors: inout [String]) {
        if !trigger.modifiers.subtracting(.supported).isEmpty {
            errors.append("The trigger uses unsupported modifier keys.")
        }
        switch trigger.kind {
        case .shortcut, .doubleShortcut:
            validateShortcut(keyCode: trigger.keyCode, modifiers: trigger.modifiers, prefix: "Trigger: ", errors: &errors)
        case .mouseButton:
            if !(0...31).contains(trigger.mouseButton) { errors.append("Mouse button must be between 0 and 31.") }
        case .scroll: break
        case .appActivated, .appLaunched, .appTerminated:
            if !validBundleIdentifier(trigger.appBundleIdentifier) {
                errors.append(trigger.kind == .appActivated
                              ? "Choose an app bundle identifier for the activation trigger."
                              : "Choose an app bundle identifier for the application lifecycle trigger.")
            }
        case .interval:
            if !trigger.intervalSeconds.isFinite || !(minimumIntervalSeconds...maximumIntervalSeconds).contains(trigger.intervalSeconds) {
                errors.append("Interval must be between 1 and 86400 seconds.")
            }
        }
    }

    private static func validateShortcut(keyCode: UInt16, modifiers: ModifierKeys, prefix: String, errors: inout [String]) {
        errors.append(contentsOf: ActionPreflight.shortcutErrors(keyCode: keyCode, modifiers: modifiers).map { prefix + $0 })
    }

    private static func validBundleIdentifier(_ value: String) -> Bool {
        ActionPreflight.validBundleIdentifier(value)
    }

    private static func sameTrigger(_ first: Trigger, _ second: Trigger) -> Bool {
        let shortcutKinds: Set<TriggerKind> = [.shortcut, .doubleShortcut]
        if shortcutKinds.contains(first.kind) && shortcutKinds.contains(second.kind) {
            // Single presses still fire while a double press is being recognized.
            return first.keyCode == second.keyCode && first.modifiers == second.modifiers
        }
        guard first.kind == second.kind else { return false }
        switch first.kind {
        case .shortcut, .doubleShortcut: return first.keyCode == second.keyCode && first.modifiers == second.modifiers
        case .mouseButton: return first.mouseButton == second.mouseButton && first.modifiers == second.modifiers
        case .scroll: return first.scrollDirection == second.scrollDirection && first.modifiers == second.modifiers
        case .appActivated, .appLaunched, .appTerminated:
            return RuleConditions.normalized(first.appBundleIdentifier) == RuleConditions.normalized(second.appBundleIdentifier)
        case .interval: return first.intervalSeconds == second.intervalSeconds
        }
    }

    private static func conditionsOverlap(_ first: AutomationRule, _ second: AutomationRule) -> Bool {
        if first.trigger.kind == .appActivated {
            return first.conditions.matches(bundleIdentifier: first.trigger.appBundleIdentifier) &&
                second.conditions.matches(bundleIdentifier: first.trigger.appBundleIdentifier)
        }
        let firstIncluded = Set(first.conditions.appBundleIdentifiers.map(RuleConditions.normalized))
        let secondIncluded = Set(second.conditions.appBundleIdentifiers.map(RuleConditions.normalized))
        let excluded = Set((first.conditions.excludedAppBundleIdentifiers + second.conditions.excludedAppBundleIdentifiers).map(RuleConditions.normalized))
        if firstIncluded.isEmpty && secondIncluded.isEmpty { return true }
        let candidates: Set<String>
        if firstIncluded.isEmpty { candidates = secondIncluded }
        else if secondIncluded.isEmpty { candidates = firstIncluded }
        else { candidates = firstIncluded.intersection(secondIncluded) }
        return !candidates.subtracting(excluded).isEmpty
    }
}
