import Foundation

public enum AutomationCapability: String, CaseIterable, Identifiable, Codable, Sendable {
    case inputMonitoring, accessibility, notifications, scripts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        case .notifications: return "Notifications"
        case .scripts: return "Shell scripts"
        }
    }

    public var detail: String {
        switch self {
        case .inputMonitoring:
            return "Observe global keyboard shortcuts, mouse buttons, and scroll gestures. Manual runs do not need this permission."
        case .accessibility:
            return "Move or resize windows, press menu items, and send keyboard shortcuts or text to the target app."
        case .notifications:
            return "Show notifications from notification actions."
        case .scripts:
            return "Allow shell script actions in ActionFlow settings. Scripts are off by default."
        }
    }
}

/// Describes prerequisites without querying permissions, running actions, or changing a rule.
public enum RuleRequirements {
    public static func capabilities(for rule: AutomationRule, automatic: Bool) -> [AutomationCapability] {
        var required = Set<AutomationCapability>()
        if automatic {
            switch rule.trigger.kind {
            case .shortcut, .doubleShortcut, .mouseButton, .scroll:
                required.insert(.inputMonitoring)
            case .appActivated, .appLaunched, .appTerminated, .interval:
                break
            }
        }
        for action in rule.actions {
            switch action.kind {
            case .window, .keyboardShortcut, .insertText, .menuCommand:
                required.insert(.accessibility)
            case .notification:
                required.insert(.notifications)
            case .shellScript:
                required.insert(.scripts)
            case .openURL, .launchApp, .delay:
                break
            }
        }
        return AutomationCapability.allCases.filter { required.contains($0) }
    }

    public static func missing(for rule: AutomationRule, automatic: Bool,
                               available: Set<AutomationCapability>) -> [AutomationCapability] {
        capabilities(for: rule, automatic: automatic).filter { !available.contains($0) }
    }
}
