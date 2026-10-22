import Foundation

public struct ModifierKeys: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    // Match CGEventFlags so the runtime can convert without a translation table.
    public static let shift = ModifierKeys(rawValue: 1 << 17)
    public static let control = ModifierKeys(rawValue: 1 << 18)
    public static let option = ModifierKeys(rawValue: 1 << 19)
    public static let command = ModifierKeys(rawValue: 1 << 20)
    public static let supported: ModifierKeys = [.command, .option, .control, .shift]

    public var displayString: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }.map { $0.1 }.joined()
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TriggerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case shortcut, doubleShortcut, mouseButton, scroll, appActivated, appLaunched, appTerminated, interval
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .shortcut: return "Keyboard shortcut"
        case .doubleShortcut: return "Double-press shortcut"
        case .mouseButton: return "Mouse button"
        case .scroll: return "Scroll gesture"
        case .appActivated: return "App activated"
        case .appLaunched: return "Application launched"
        case .appTerminated: return "Application terminated"
        case .interval: return "Time interval"
        }
    }
}

public enum ScrollDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case up, down, left, right
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct Trigger: Codable, Equatable, Sendable {
    public var kind: TriggerKind
    public var keyCode: UInt16
    public var modifiers: ModifierKeys
    public var mouseButton: Int
    public var scrollDirection: ScrollDirection
    public var intervalSeconds: Double
    public var appBundleIdentifier: String

    public init(kind: TriggerKind = .shortcut, keyCode: UInt16 = 0,
                modifiers: ModifierKeys = [.control, .option], mouseButton: Int = 2,
                scrollDirection: ScrollDirection = .up, intervalSeconds: Double = 60,
                appBundleIdentifier: String = "") {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mouseButton = mouseButton
        self.scrollDirection = scrollDirection
        self.intervalSeconds = intervalSeconds
        self.appBundleIdentifier = appBundleIdentifier
    }

    public var summary: String {
        switch kind {
        case .shortcut: return "\(modifiers.displayString)\(KeyCodeLabel.label(for: keyCode))"
        case .doubleShortcut: return "\(modifiers.displayString)\(KeyCodeLabel.label(for: keyCode)) × 2"
        case .mouseButton:
            let buttonLabel = mouseButton == Int.max ? String(mouseButton) : String(mouseButton + 1)
            return "\(modifiers.displayString)Mouse button \(buttonLabel)"
        case .scroll: return "\(modifiers.displayString)Scroll \(scrollDirection.title.lowercased())"
        case .appActivated: return "App activates: \(appBundleIdentifier.isEmpty ? "Choose an app" : appBundleIdentifier)"
        case .appLaunched: return "App launched: \(appBundleIdentifier.isEmpty ? "Choose an app" : appBundleIdentifier)"
        case .appTerminated: return "App terminated: \(appBundleIdentifier.isEmpty ? "Choose an app" : appBundleIdentifier)"
        case .interval: return "Every \(intervalSeconds.formatted()) seconds"
        }
    }
}

public struct RuleConditions: Codable, Equatable, Sendable {
    public var appBundleIdentifiers: [String]
    public var excludedAppBundleIdentifiers: [String]
    public init(appBundleIdentifiers: [String] = [], excludedAppBundleIdentifiers: [String] = []) {
        self.appBundleIdentifiers = appBundleIdentifiers
        self.excludedAppBundleIdentifiers = excludedAppBundleIdentifiers
    }

    public func matches(bundleIdentifier: String) -> Bool {
        let identifier = Self.normalized(bundleIdentifier)
        let included = appBundleIdentifiers.map(Self.normalized)
        let excluded = excludedAppBundleIdentifiers.map(Self.normalized)
        return !excluded.contains(identifier) && (included.isEmpty || included.contains(identifier))
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum ActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case window, keyboardShortcut, insertText, openURL, launchApp, delay, notification, shellScript, menuCommand
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .window: return "Move or resize window"
        case .keyboardShortcut: return "Send keyboard shortcut"
        case .insertText: return "Insert text"
        case .openURL: return "Open URL"
        case .launchApp: return "Launch app"
        case .delay: return "Wait"
        case .notification: return "Show notification"
        case .shellScript: return "Run shell script"
        case .menuCommand: return "Run menu command"
        }
    }
}

public enum WindowOperation: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center, centerTwoThirds, larger, smaller, nextDisplay, restore
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .topLeft: return "Top-left quarter"
        case .topRight: return "Top-right quarter"
        case .bottomLeft: return "Bottom-left quarter"
        case .bottomRight: return "Bottom-right quarter"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .centerTwoThirds: return "Center two thirds"
        case .larger: return "Make 10% larger"
        case .smaller: return "Make 10% smaller"
        case .nextDisplay: return "Move to next display"
        case .restore: return "Restore previous size"
        }
    }
}

public struct AutomationAction: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ActionKind
    public var text: String
    public var keyCode: UInt16
    public var modifiers: ModifierKeys
    public var windowOperation: WindowOperation
    public var delaySeconds: Double

    public init(id: UUID = UUID(), kind: ActionKind = .window, text: String = "",
                keyCode: UInt16 = 0, modifiers: ModifierKeys = [.command],
                windowOperation: WindowOperation = .leftHalf, delaySeconds: Double = 1) {
        self.id = id
        self.kind = kind
        self.text = text
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.windowOperation = windowOperation
        self.delaySeconds = delaySeconds
    }

    public var summary: String {
        switch kind {
        case .window: return windowOperation.title
        case .keyboardShortcut: return "Send \(modifiers.displayString)\(KeyCodeLabel.label(for: keyCode))"
        case .insertText: return "Insert \(text.count) characters"
        case .openURL: return "Open \(text.prefix(100))"
        case .launchApp: return "Launch \(text.prefix(100))"
        case .delay: return "Wait \(delaySeconds.formatted()) seconds"
        case .notification: return String(text.prefix(100))
        case .shellScript: return "Run shell script (requires opt-in)"
        case .menuCommand: return "Run a menu command by exact titles (titles hidden)"
        }
    }
}

public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var group: String
    public var trigger: Trigger
    public var conditions: RuleConditions
    public var actions: [AutomationAction]
    public var cooldown: Double

    public init(id: UUID = UUID(), name: String = "New rule", enabled: Bool = false,
                group: String = "My rules", trigger: Trigger = Trigger(),
                conditions: RuleConditions = RuleConditions(),
                actions: [AutomationAction] = [AutomationAction()], cooldown: Double = 0.5) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.group = group
        self.trigger = trigger
        self.conditions = conditions
        self.actions = actions
        self.cooldown = cooldown
    }

    public static var exampleRules: [AutomationRule] {
        [
            AutomationRule(name: "Window to left half", group: "Window management",
                           trigger: Trigger(keyCode: 123),
                           actions: [AutomationAction(windowOperation: .leftHalf)]),
            AutomationRule(name: "Window to right half", group: "Window management",
                           trigger: Trigger(keyCode: 124),
                           actions: [AutomationAction(windowOperation: .rightHalf)]),
            AutomationRule(name: "Focus workspace", group: "Getting started",
                           trigger: Trigger(keyCode: 3),
                           actions: [AutomationAction(windowOperation: .maximize),
                                     AutomationAction(kind: .notification, text: "Your workspace is ready.")])
        ]
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var rules: [AutomationRule]
    public var automationEnabled: Bool
    public var allowScripts: Bool
    public var launchAtLogin: Bool

    public init(schemaVersion: Int = Configuration.currentSchemaVersion,
                rules: [AutomationRule] = AutomationRule.exampleRules,
                automationEnabled: Bool = false, allowScripts: Bool = false, launchAtLogin: Bool = false) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.automationEnabled = automationEnabled
        self.allowScripts = allowScripts
        self.launchAtLogin = launchAtLogin
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, rules, automationEnabled, allowScripts, launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Files must identify their schema. Optional settings may be absent in v1 exports.
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        rules = try values.decode([AutomationRule].self, forKey: .rules)
        automationEnabled = try values.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? false
        allowScripts = try values.decodeIfPresent(Bool.self, forKey: .allowScripts) ?? false
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }
}

/// Physical ANSI key labels, not a keyboard-layout-dependent shortcut recorder.
public enum KeyCodeLabel {
    public static func label(for code: UInt16) -> String {
        let labels: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8",
            29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
            46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            109: "F10", 111: "F12", 115: "Home", 116: "Page Up", 117: "Forward Delete",
            118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return labels[code] ?? "Key \(code)"
    }
}
