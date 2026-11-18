import Foundation

public enum RuleStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, enabled, disabled, invalid

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "All states"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .invalid: return "Needs attention"
        }
    }
}

/// A read-only view of rules. Search never inspects action text, URLs, or scripts.
public struct RuleQuery: Sendable, Equatable {
    public var text: String
    public var status: RuleStatusFilter
    /// nil means every group. An empty string means the actual ungrouped value.
    public var group: String?

    public init(text: String = "", status: RuleStatusFilter = .all, group: String? = nil) {
        self.text = text
        self.status = status
        self.group = group
    }

    public func matches(_ rule: AutomationRule) -> Bool {
        passesFilters(rule) && (text.isEmpty || fieldsContainText(rule))
    }

    /// Like `matches`, and additionally searches caller-supplied display text (for example a localized trigger summary).
    /// The closure is not called when the search text is empty or the rule is excluded by its group or status.
    public func matches(_ rule: AutomationRule, displayText: (AutomationRule) -> String) -> Bool {
        guard passesFilters(rule) else { return false }
        if text.isEmpty || fieldsContainText(rule) { return true }
        return displayText(rule).localizedCaseInsensitiveContains(text)
    }

    public func apply(to rules: [AutomationRule]) -> [AutomationRule] { rules.filter { matches($0) } }

    public func apply(to rules: [AutomationRule], displayText: (AutomationRule) -> String) -> [AutomationRule] {
        rules.filter { matches($0, displayText: displayText) }
    }

    private func passesFilters(_ rule: AutomationRule) -> Bool {
        if let group, rule.group != group { return false }
        switch status {
        case .all: break
        case .enabled: if !rule.enabled { return false }
        case .disabled: if rule.enabled { return false }
        case .invalid: if RuleValidator.validate(rule).isEmpty { return false }
        }
        return true
    }

    private func fieldsContainText(_ rule: AutomationRule) -> Bool {
        rule.name.localizedCaseInsensitiveContains(text) ||
            rule.group.localizedCaseInsensitiveContains(text) || rule.trigger.summary.localizedCaseInsensitiveContains(text)
    }

    /// Preserve user-written names exactly, including whitespace and the empty group.
    /// Lexical sorting avoids locale-dependent ordering of group choices.
    public static func groups(in rules: [AutomationRule]) -> [String] { Set(rules.map(\.group)).sorted() }
}
