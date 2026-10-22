import Foundation

/// A built-in catalog entry, not an executable or a third-party configuration download.
public struct RuleTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let rules: [AutomationRule]

    /// Canonical export content. Identifiers are stable and all execution opt-ins are off.
    public var configuration: Configuration {
        var disabled = rules
        for index in disabled.indices { disabled[index].enabled = false }
        return Configuration(rules: disabled, automationEnabled: false, allowScripts: false, launchAtLogin: false)
    }

    /// Use independent identities when installing a pack, including repeated installations.
    public func makeRules() -> [AutomationRule] {
        rules.map { original in
            var copy = original
            copy.id = UUID()
            copy.enabled = false
            for index in copy.actions.indices { copy.actions[index].id = UUID() }
            return copy
        }
    }
}

public enum RuleTemplates {
    public static let all: [RuleTemplate] = [
        RuleTemplate(
            id: "window-halves", name: "Window halves",
            detail: "Place the focused window on the left or right half of its display.",
            rules: [
                windowRule(pack: 1, number: 1, name: "Window to left half", keyCode: 123, operation: .leftHalf),
                windowRule(pack: 1, number: 2, name: "Window to right half", keyCode: 124, operation: .rightHalf)
            ]
        ),
        RuleTemplate(
            id: "window-quarters", name: "Window quarters",
            detail: "Arrange the focused window in any quarter of its display.",
            rules: [
                windowRule(pack: 2, number: 1, name: "Window to top-left quarter", keyCode: 32, operation: .topLeft),
                windowRule(pack: 2, number: 2, name: "Window to top-right quarter", keyCode: 34, operation: .topRight),
                windowRule(pack: 2, number: 3, name: "Window to bottom-left quarter", keyCode: 38, operation: .bottomLeft),
                windowRule(pack: 2, number: 4, name: "Window to bottom-right quarter", keyCode: 40, operation: .bottomRight)
            ]
        ),
        RuleTemplate(
            id: "focus-workspace", name: "Focus workspace",
            detail: "Maximize or center the focused window with a keyboard shortcut.",
            rules: [
                windowRule(pack: 3, number: 1, name: "Maximize focused window", keyCode: 36, operation: .maximize),
                windowRule(pack: 3, number: 2, name: "Center focused window", keyCode: 8, operation: .center)
            ]
        ),
        RuleTemplate(
            id: "launch-browser", name: "Launch Safari",
            detail: "Request Safari by bundle identifier. Requires Safari to be installed.",
            rules: [
                AutomationRule(id: identifier(pack: 4, rule: 1), name: "Launch Safari", enabled: false,
                               group: "Built-in templates", trigger: Trigger(keyCode: 11, modifiers: [.control, .option]),
                               actions: [AutomationAction(id: identifier(pack: 4, rule: 1, action: 1),
                                                          kind: .launchApp, text: "com.apple.Safari")])
            ]
        ),
        RuleTemplate(
            id: "meeting-notes", name: "Meeting notes starter",
            detail: "Double-press a shortcut to insert a generic notes outline into the focused text field.",
            rules: [
                AutomationRule(id: identifier(pack: 5, rule: 1), name: "Insert meeting notes outline", enabled: false,
                               group: "Built-in templates",
                               trigger: Trigger(kind: .doubleShortcut, keyCode: 45, modifiers: [.control, .option]),
                               actions: [AutomationAction(id: identifier(pack: 5, rule: 1, action: 1), kind: .insertText,
                                                          text: "Meeting notes\n\nTopic: \nNotes: \nNext steps: \n")])
            ]
        ),
        RuleTemplate(
            id: "gentle-reminder", name: "Gentle reminder",
            detail: "Show a reminder every 30 minutes while automation is enabled.",
            rules: [
                AutomationRule(id: identifier(pack: 6, rule: 1), name: "Take a short break", enabled: false,
                               group: "Built-in templates", trigger: Trigger(kind: .interval, intervalSeconds: 1_800),
                               actions: [AutomationAction(id: identifier(pack: 6, rule: 1, action: 1), kind: .notification,
                                                          text: "A gentle reminder to take a short break.")], cooldown: 1_800)
            ]
        )
    ]

    public static func find(id: String) -> RuleTemplate? { all.first { $0.id == id } }

    private static func windowRule(pack: Int, number: Int, name: String, keyCode: UInt16,
                                   operation: WindowOperation) -> AutomationRule {
        AutomationRule(id: identifier(pack: pack, rule: number), name: name, enabled: false,
                       group: "Built-in templates", trigger: Trigger(keyCode: keyCode, modifiers: [.control, .option]),
                       actions: [AutomationAction(id: identifier(pack: pack, rule: number, action: 1), windowOperation: operation)])
    }

    /// Reserved UUID prefix with explicit pack, rule, and action slots. A zero action slot is a rule.
    private static func identifier(pack: Int, rule: Int, action: Int = 0) -> UUID {
        UUID(uuidString: String(format: "47465450-%04X-%04X-8000-%012X", pack, rule, action))!
    }
}
