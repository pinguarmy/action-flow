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
        conflictPairs(in: rules).map(\.message)
    }

    /// Conflicting pairs of enabled rules, ordered by the position of the first rule among the enabled
    /// rules and then by the position of the second. `first` always precedes `second` in the input.
    /// Rules are bucketed by trigger so only rules sharing a trigger are compared pairwise.
    public static func conflictPairs(in rules: [AutomationRule]) -> [RuleConflict] {
        let enabled = rules.filter(\.enabled)
        var buckets: [ConflictTriggerKey: [Int]] = [:]
        for index in enabled.indices {
            guard let key = conflictKey(for: enabled[index].trigger) else { continue }
            buckets[key, default: []].append(index)
        }
        var pairs: [ConflictIndexPair] = []
        for members in buckets.values where members.count > 1 {
            // Members are in ascending input order because they were appended in order.
            for firstPosition in 0..<(members.count - 1) {
                for secondPosition in (firstPosition + 1)..<members.count {
                    let firstIndex = members[firstPosition]
                    let secondIndex = members[secondPosition]
                    if conditionsOverlap(enabled[firstIndex], enabled[secondIndex]) {
                        pairs.append(ConflictIndexPair(first: firstIndex, second: secondIndex))
                    }
                }
            }
        }
        pairs.sort { lhs, rhs in
            lhs.first != rhs.first ? lhs.first < rhs.first : lhs.second < rhs.second
        }
        return pairs.map { RuleConflict(first: enabled[$0.first], second: enabled[$0.second]) }
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

    private struct ConflictIndexPair {
        let first: Int
        let second: Int
    }

    /// Two triggers collide exactly when their keys are equal.
    private enum ConflictTriggerKey: Hashable {
        // Single presses still fire while a double press is being recognized, so both kinds share a key.
        case shortcut(keyCode: UInt16, modifiers: UInt64)
        case mouseButton(button: Int, modifiers: UInt64)
        case scroll(direction: ScrollDirection, modifiers: UInt64)
        case application(kind: TriggerKind, bundleIdentifier: String)
        case interval(bitPattern: UInt64)
    }

    /// Nil when the trigger can never equal another trigger (a NaN interval is unequal to every value).
    private static func conflictKey(for trigger: Trigger) -> ConflictTriggerKey? {
        switch trigger.kind {
        case .shortcut, .doubleShortcut:
            return .shortcut(keyCode: trigger.keyCode, modifiers: trigger.modifiers.rawValue)
        case .mouseButton:
            return .mouseButton(button: trigger.mouseButton, modifiers: trigger.modifiers.rawValue)
        case .scroll:
            return .scroll(direction: trigger.scrollDirection, modifiers: trigger.modifiers.rawValue)
        case .appActivated, .appLaunched, .appTerminated:
            return .application(kind: trigger.kind, bundleIdentifier: RuleConditions.normalized(trigger.appBundleIdentifier))
        case .interval:
            let seconds = trigger.intervalSeconds
            if seconds.isNaN { return nil }
            // -0.0 == 0.0, so both zeros share one key. Other non-NaN values are equal only with equal bits.
            let canonical: Double = seconds == 0 ? 0 : seconds
            return .interval(bitPattern: canonical.bitPattern)
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

/// Two enabled rules that share a trigger in overlapping apps. `first` precedes `second` in the input.
public struct RuleConflict: Equatable, Sendable {
    public let first: AutomationRule
    public let second: AutomationRule

    public init(first: AutomationRule, second: AutomationRule) {
        self.first = first
        self.second = second
    }

    /// The exact message `RuleValidator.conflicts(in:)` reports for this pair.
    public var message: String {
        "\"\(first.name)\" and \"\(second.name)\" share \(first.trigger.summary) in overlapping apps."
    }
}
