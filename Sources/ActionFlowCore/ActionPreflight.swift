import Foundation

/// Deterministic action checks shared by validation, previews, and the runtime.
/// Errors never include user text, scripts, URLs, app identifiers, or rule names.
public enum ActionPreflight {
    public static let maximumActions = 64
    public static let maximumInsertedTextUTF16Units = 16_384
    public static let maximumCharacterUTF16Units = 256
    public static let maximumScriptBytes = 16_384
    public static let maximumNotificationBytes = 4_096
    public static let maximumURLBytes = 8_192
    public static let maximumAppIdentifierBytes = 255
    public static let maximumDelaySeconds: Double = 60
    public static let maximumTotalDelaySeconds: Double = 120
    public static let chainDeadlineSeconds: Double = 120
    public static let textCharacterPauseSeconds: Double = 0.012
    /// Leave one second for ordinary scheduling overhead. This is a minimum
    /// planned-time check, not a promise about app launch, scripts, or OS latency.
    public static let executionBudgetSeconds: Double = 119

    public static func errors(for actions: [AutomationAction]) -> [String] {
        var errors: [String] = []
        if actions.isEmpty { errors.append("Add at least one action.") }
        if actions.count > maximumActions { errors.append("A rule cannot have more than 64 actions.") }
        if Set(actions.map(\.id)).count != actions.count {
            errors.append("Action identifiers must be unique within a rule.")
        }
        var totalDelay: Double = 0
        var insertedCharacterCount = 0
        for (index, action) in actions.enumerated() {
            let prefix = "Action \(index + 1): "
            if action.text.contains("\0") { errors.append("Action text cannot contain NUL characters.") }
            switch action.kind {
            case .window: break
            case .keyboardShortcut:
                errors.append(contentsOf: shortcutErrors(keyCode: action.keyCode, modifiers: action.modifiers).map { prefix + $0 })
            case .insertText, .notification, .shellScript:
                if action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append(prefix + "Enter text to use for this action.")
                }
                switch action.kind {
                case .insertText:
                    insertedCharacterCount += action.text.count
                    if action.text.utf16.count > maximumInsertedTextUTF16Units {
                        errors.append(prefix + "Inserted text is limited to 16,384 UTF-16 units.")
                    }
                    if action.text.contains(where: { String($0).utf16.count > maximumCharacterUTF16Units }) {
                        errors.append(prefix + "A text character cannot exceed 256 UTF-16 units.")
                    }
                case .notification:
                    if action.text.utf8.count > maximumNotificationBytes {
                        errors.append(prefix + "Notification text cannot exceed 4096 UTF-8 bytes.")
                    }
                case .shellScript:
                    if action.text.utf8.count > maximumScriptBytes {
                        errors.append(prefix + "Shell scripts cannot exceed 16384 UTF-8 bytes.")
                    }
                default: break
                }
            case .openURL:
                if action.text.utf8.count > maximumURLBytes {
                    errors.append(prefix + "URLs cannot exceed 8192 UTF-8 bytes.")
                }
                errors.append(contentsOf: urlErrors(action.text).map { prefix + $0 })
            case .launchApp:
                if !validBundleIdentifier(action.text) {
                    errors.append(prefix + "Enter an app bundle identifier, such as com.apple.Safari.")
                }
            case .menuCommand:
                do { _ = try MenuCommandPath(parsing: action.text) }
                catch let error as MenuCommandPathError { errors.append(prefix + error.message) }
                catch { errors.append(prefix + MenuCommandPathError.invalidJSON.message) }
            case .delay:
                if !action.delaySeconds.isFinite || !(0...maximumDelaySeconds).contains(action.delaySeconds) {
                    errors.append(prefix + "Wait time must be between 0 and 60 seconds.")
                } else { totalDelay += action.delaySeconds }
            }
        }
        if totalDelay > maximumTotalDelaySeconds {
            errors.append("Total wait time cannot exceed 120 seconds.")
        }
        let minimumPlannedSeconds = totalDelay + Double(insertedCharacterCount) * (2 * textCharacterPauseSeconds)
        if minimumPlannedSeconds > executionBudgetSeconds {
            errors.append("Planned waits and text insertion exceed the 119-second execution budget.")
        }
        var seen = Set<String>()
        return errors.filter { seen.insert($0).inserted }
    }

    static func shortcutErrors(keyCode: UInt16, modifiers: ModifierKeys) -> [String] {
        var errors: [String] = []
        if keyCode > 127 { errors.append("Key code must be between 0 and 127.") }
        if modifiers.intersection([.command, .option, .control]).isEmpty {
            errors.append("Use Command, Option, or Control to avoid triggering while typing.")
        }
        if !modifiers.subtracting(.supported).isEmpty { errors.append("Unsupported modifier keys.") }
        return errors
    }

    private static func urlErrors(_ value: String) -> [String] {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme) else {
            return ["Use an http, https, or mailto URL."]
        }
        var errors: [String] = []
        if scheme == "mailto" {
            if !validMailtoRecipients(value) { errors.append("Enter an email address in the mailto URL.") }
        } else if url.host?.isEmpty != false { errors.append("The URL needs a host name.") }
        if value.contains(where: { $0.isNewline || $0 == "\0" }) {
            errors.append("URLs cannot contain line breaks or NUL characters.")
        }
        return errors
    }

    private static func validMailtoRecipients(_ value: String) -> Bool {
        // Opaque mailto path handling differs across Foundation versions. Parse the original URI.
        guard let colon = value.firstIndex(of: ":") else { return false }
        let schemeSpecific = value[value.index(after: colon)...]
        let encodedRecipients = schemeSpecific.prefix { $0 != "?" && $0 != "#" }
        guard !encodedRecipients.isEmpty else { return false }
        return encodedRecipients.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { encoded in
            guard let recipient = String(encoded).removingPercentEncoding,
                  !recipient.isEmpty,
                  recipient.unicodeScalars.allSatisfy({
                      !CharacterSet.whitespacesAndNewlines.contains($0) &&
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  !recipient.contains(where: { "/?#".contains($0) }) else { return false }
            let parts = recipient.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
        }
    }

    static func validBundleIdentifier(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.count <= maximumAppIdentifierBytes, value.contains(".") else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
            }
        }
    }
}

public struct ExecutionPlanStep: Codable, Equatable, Sendable {
    /// One-based order within the action chain.
    public let index: Int
    public let kind: ActionKind
    public let title: String
    public let summary: String

    fileprivate init(index: Int, action: AutomationAction) {
        self.index = index
        kind = action.kind
        title = action.kind.title
        switch action.kind {
        case .window: summary = action.windowOperation.title
        case .keyboardShortcut: summary = "Send a keyboard shortcut. Shortcut contents are hidden."
        case .insertText: summary = "Insert \(action.text.utf16.count) UTF-16 units. Text is hidden."
        case .openURL: summary = "Open a URL in the default app. The URL is hidden."
        case .launchApp: summary = "Launch an application. The bundle identifier is hidden."
        case .delay:
            if action.delaySeconds.isFinite, (0...ActionPreflight.maximumDelaySeconds).contains(action.delaySeconds) {
                summary = "Wait \(action.delaySeconds.formatted()) seconds."
            } else { summary = "Invalid wait duration. No action will run during preview." }
        case .notification: summary = "Show a notification with \(action.text.utf8.count) UTF-8 bytes. The message is hidden."
        case .shellScript: summary = "Run a shell script with \(action.text.utf8.count) UTF-8 bytes. Script contents are hidden."
        case .menuCommand:
            if let path = try? MenuCommandPath(parsing: action.text) {
                summary = "Press a menu command through \(path.segments.count) exact menu levels. Menu titles are hidden."
            } else { summary = "Invalid menu command path. No action will run during preview." }
        }
    }
}

/// A redacted description only. Constructing or encoding it never executes an action.
public struct ExecutionPlan: Codable, Equatable, Sendable {
    public let steps: [ExecutionPlanStep]
    public let requiredCapabilities: [AutomationCapability]
    public let validationErrors: [String]
    /// Sum of individually valid delays. Invalid timing values are reported in validationErrors.
    public let totalDelaySeconds: Double

    public init(rule: AutomationRule) {
        steps = rule.actions.enumerated().map { ExecutionPlanStep(index: $0.offset + 1, action: $0.element) }
        requiredCapabilities = RuleRequirements.capabilities(for: rule, automatic: true)
        validationErrors = RuleValidator.validate(rule)
        totalDelaySeconds = rule.actions.reduce(0) { sum, action in
            guard action.kind == .delay, action.delaySeconds.isFinite,
                  (0...ActionPreflight.maximumDelaySeconds).contains(action.delaySeconds) else { return sum }
            return sum + action.delaySeconds
        }
    }
}
