import Foundation

/// Which kinds of input the currently enabled rules can react to. Pure data; never observes input.
public struct TriggerInterest: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Any enabled `.shortcut` or `.doubleShortcut` rule.
    public static let keyboard = TriggerInterest(rawValue: 1 << 0)
    /// Any enabled `.mouseButton` rule.
    public static let mouseButtons = TriggerInterest(rawValue: 1 << 1)
    /// Any enabled `.scroll` rule.
    public static let scroll = TriggerInterest(rawValue: 1 << 2)
    /// Any enabled `.appActivated` rule.
    public static let appActivation = TriggerInterest(rawValue: 1 << 3)
    /// Any enabled `.appLaunched` or `.appTerminated` rule.
    public static let appLifecycle = TriggerInterest(rawValue: 1 << 4)
    /// Any enabled `.interval` rule.
    public static let interval = TriggerInterest(rawValue: 1 << 5)
    /// Any enabled `.shortcut` rule with `passThrough == false` and a valid shortcut: its key press may be
    /// kept from the active app. Always accompanied by `.keyboard`; not an input kind of its own.
    public static let shortcutInterception = TriggerInterest(rawValue: 1 << 6)

    /// Interest of the enabled rules only. Disabled rules contribute nothing.
    public init(rules: [AutomationRule]) {
        var value = 0
        for rule in rules where rule.enabled {
            value |= TriggerInterest.interest(for: rule.trigger.kind).rawValue
            if ShortcutInterception.canConsume(rule.trigger) {
                value |= TriggerInterest.shortcutInterception.rawValue
            }
        }
        self.init(rawValue: value)
    }

    /// True when an observed signal of this kind could match some enabled rule.
    /// A `.shortcut` signal is wanted when `.keyboard` is present (double-press rules are fed by ordinary
    /// shortcut signals). `.doubleShortcut` belongs to the same keyboard family.
    public func wants(_ signalKind: TriggerKind) -> Bool {
        contains(TriggerInterest.interest(for: signalKind))
    }

    /// True when any global input observation (keyboard, mouse buttons or scroll) is needed.
    public var needsInputMonitoring: Bool {
        !isDisjoint(with: TriggerInterest.inputMonitoring)
    }

    private static let inputMonitoring: TriggerInterest = [.keyboard, .mouseButtons, .scroll]

    private static func interest(for kind: TriggerKind) -> TriggerInterest {
        switch kind {
        case .shortcut, .doubleShortcut: return .keyboard
        case .mouseButton: return .mouseButtons
        case .scroll: return .scroll
        case .appActivated: return .appActivation
        case .appLaunched, .appTerminated: return .appLifecycle
        case .interval: return .interval
        }
    }
}

/// Decides whether an observed key press belongs to a rule and should not also reach the active app.
/// Pure data: never observes input or runs actions.
public enum ShortcutInterception {
    /// True when some enabled `.shortcut` rule with `passThrough == false` has exactly this keyCode and
    /// modifiers and its app conditions match `bundleIdentifier`. Double-press rules never consume (their
    /// first press cannot be known to be half of a pair). Deliberately independent of cooldown and scheduler
    /// state: an owned chord is consumed on every press and on key auto-repeat, even while its rule is
    /// cooling down or busy. A trigger that fails shortcut validation (for example an in-memory draft
    /// without Command, Option or Control) never consumes, so ordinary typing cannot be swallowed.
    public static func consumes(keyCode: UInt16, modifiers: ModifierKeys, rules: [AutomationRule],
                                bundleIdentifier: String) -> Bool {
        rules.contains { rule in
            rule.enabled && canConsume(rule.trigger) &&
                rule.trigger.keyCode == keyCode && rule.trigger.modifiers == modifiers &&
                rule.conditions.matches(bundleIdentifier: bundleIdentifier)
        }
    }

    /// The trigger itself allows consuming its key press, independent of the enabled state and app conditions.
    static func canConsume(_ trigger: Trigger) -> Bool {
        trigger.kind == .shortcut && !trigger.passThrough &&
            ActionPreflight.shortcutErrors(keyCode: trigger.keyCode, modifiers: trigger.modifiers).isEmpty
    }
}
