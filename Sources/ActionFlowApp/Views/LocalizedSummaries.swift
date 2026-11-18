import Foundation
import ActionFlowCore

/// Display-only counterparts of ActionFlowCore's English summaries. Core keeps its
/// English text for search, export and tests; views show these localized versions.
enum LocalizedKeyLabel {
    static func label(for keyCode: UInt16) -> String {
        let label = KeyCodeLabel.label(for: keyCode)
        if label == "Key \(keyCode)" { return AppLocalization.format("Key %lld", Int64(keyCode)) }
        // Symbols and letters have no table entry and are returned unchanged.
        return AppLocalization.text(label)
    }
}

extension Trigger {
    var localizedSummary: String {
        let modifierSymbols = modifiers.displayString
        switch kind {
        case .shortcut:
            return modifierSymbols + LocalizedKeyLabel.label(for: keyCode)
        case .doubleShortcut:
            return AppLocalization.format("%@ × 2", modifierSymbols + LocalizedKeyLabel.label(for: keyCode))
        case .mouseButton:
            let buttonLabel = mouseButton == Int.max ? String(mouseButton) : String(mouseButton + 1)
            return AppLocalization.format("%@Mouse button %@", modifierSymbols, buttonLabel)
        case .scroll:
            switch scrollDirection {
            case .up: return AppLocalization.format("%@Scroll up", modifierSymbols)
            case .down: return AppLocalization.format("%@Scroll down", modifierSymbols)
            case .left: return AppLocalization.format("%@Scroll left", modifierSymbols)
            case .right: return AppLocalization.format("%@Scroll right", modifierSymbols)
            }
        case .appActivated:
            return AppLocalization.format("App activates: %@", localizedAppIdentifier)
        case .appLaunched:
            return AppLocalization.format("App launched: %@", localizedAppIdentifier)
        case .appTerminated:
            return AppLocalization.format("App terminated: %@", localizedAppIdentifier)
        case .interval:
            return AppLocalization.format("Every %@ seconds", intervalSeconds.formatted())
        }
    }

    private var localizedAppIdentifier: String {
        appBundleIdentifier.isEmpty ? AppLocalization.text("Choose an app") : appBundleIdentifier
    }
}

extension AutomationAction {
    var localizedSummary: String {
        switch kind {
        case .window:
            return AppLocalization.text(windowOperation.title)
        case .keyboardShortcut:
            return AppLocalization.format("Send %@", modifiers.displayString + LocalizedKeyLabel.label(for: keyCode))
        case .insertText:
            return AppLocalization.format("Insert %lld characters", Int64(text.count))
        case .openURL:
            return AppLocalization.format("Open %@", String(text.prefix(100)))
        case .launchApp:
            return AppLocalization.format("Launch %@", String(text.prefix(100)))
        case .delay:
            return AppLocalization.format("Wait %@ seconds", delaySeconds.formatted())
        case .notification:
            return String(text.prefix(100))
        case .shellScript:
            return AppLocalization.text("Run shell script (requires opt-in)")
        case .menuCommand:
            return AppLocalization.text("Run a menu command by exact titles (titles hidden)")
        }
    }
}

extension ExecutionPlanStep {
    /// ExecutionPlanStep only carries Core's redacted English summary, so fixed summaries are
    /// looked up directly and counted ones are matched against Core's known templates.
    var localizedSummary: String {
        if let translated = AppLocalization.lookup(summary) { return translated }
        let integerTemplates: [(pattern: String, key: String)] = [
            (#"^Insert (\d+) UTF-16 units\. Text is hidden\.$"#, "Insert %lld UTF-16 units. Text is hidden."),
            (#"^Show a notification with (\d+) UTF-8 bytes\. The message is hidden\.$"#, "Show a notification with %lld UTF-8 bytes. The message is hidden."),
            (#"^Run a shell script with (\d+) UTF-8 bytes\. Script contents are hidden\.$"#, "Run a shell script with %lld UTF-8 bytes. Script contents are hidden."),
            (#"^Press a menu command through (\d+) exact menu levels\. Menu titles are hidden\.$"#, "Press a menu command through %lld exact menu levels. Menu titles are hidden.")
        ]
        for template in integerTemplates {
            if let captured = Self.firstCapture(in: summary, pattern: template.pattern), let count = Int64(captured) {
                return AppLocalization.format(template.key, count)
            }
        }
        if kind == .delay, let seconds = Self.firstCapture(in: summary, pattern: #"^Wait (.+) seconds\.$"#) {
            return AppLocalization.format("Wait %@ seconds.", seconds)
        }
        return summary
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
