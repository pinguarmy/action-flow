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

    /// Interest of the enabled rules only. Disabled rules contribute nothing.
    public init(rules: [AutomationRule]) {
        var value = 0
        for rule in rules where rule.enabled {
            value |= TriggerInterest.interest(for: rule.trigger.kind).rawValue
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
