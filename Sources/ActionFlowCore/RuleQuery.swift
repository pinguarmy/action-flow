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
        if let group, rule.group != group { return false }
        switch status {
        case .all: break
        case .enabled: if !rule.enabled { return false }
        case .disabled: if rule.enabled { return false }
        case .invalid: if RuleValidator.validate(rule).isEmpty { return false }
        }
        return text.isEmpty || rule.name.localizedCaseInsensitiveContains(text) ||
            rule.group.localizedCaseInsensitiveContains(text) || rule.trigger.summary.localizedCaseInsensitiveContains(text)
    }

    public func apply(to rules: [AutomationRule]) -> [AutomationRule] { rules.filter(matches) }

    /// Preserve user-written names exactly, including whitespace and the empty group.
    /// Lexical sorting avoids locale-dependent ordering of group choices.
    public static func groups(in rules: [AutomationRule]) -> [String] { Set(rules.map(\.group)).sorted() }
}
