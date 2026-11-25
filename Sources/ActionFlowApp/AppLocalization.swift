import Foundation
import ActionFlowCore

/// Uses installed resources, with an explicit test-only locale override.
/// Unknown/user-provided strings are returned unchanged.
enum AppLocalization {
    private static let missingValue = "\u{1}ActionFlow.missingLocalization\u{1}"

    /// Looks up a printf-style key and fills it. English keys keep today's exact output.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }

    /// The table value for `key`, or nil when the key is not in the table.
    static func lookup(_ key: String) -> String? {
        let bundle = languageBundle() ?? Bundle.main
        let value = bundle.localizedString(forKey: key, value: missingValue, table: "Localizable")
        return value == missingValue ? nil : value
    }

    /// Localizes one validation or preflight message produced in English by ActionFlowCore.
    /// Unknown messages are returned unchanged.
    static func validationMessage(_ message: String) -> String {
        if let translated = lookup(message) { return translated }
        if let parsed = numberedPrefix(message, prefix: "Action ", separator: ": ") {
            return format("Action %lld: %@", parsed.number, validationMessage(parsed.rest))
        }
        if message.hasPrefix("Trigger: ") {
            return format("Trigger: %@", validationMessage(String(message.dropFirst("Trigger: ".count))))
        }
        if let parsed = numberedPrefix(message, prefix: "Rule ", separator: " (") {
            let number = parsed.number
            let tail = parsed.rest
            // "Rule <n> (<name>): <message>" where the name itself may contain "): ".
            var splits: [Range<String.Index>] = []
            var searchStart = tail.startIndex
            while searchStart < tail.endIndex, let found = tail.range(of: "): ", range: searchStart..<tail.endIndex) {
                splits.append(found)
                searchStart = found.upperBound
            }
            let known = splits.reversed().first { isKnownValidationMessage(String(tail[$0.upperBound...])) }
            if let split = known ?? splits.first {
                let name = String(tail[tail.startIndex..<split.lowerBound])
                let wrapped = String(tail[split.upperBound...])
                return format("Rule %lld (%@): %@", number, name, validationMessage(wrapped))
            }
        }
        return message
    }

    private static func isKnownValidationMessage(_ message: String) -> Bool {
        if lookup(message) != nil { return true }
        if let parsed = numberedPrefix(message, prefix: "Action ", separator: ": ") { return isKnownValidationMessage(parsed.rest) }
        if message.hasPrefix("Trigger: ") { return isKnownValidationMessage(String(message.dropFirst("Trigger: ".count))) }
        return false
    }

    /// Splits "<prefix><digits><separator><rest>" into the number and the rest.
    private static func numberedPrefix(_ message: String, prefix: String, separator: String) -> (number: Int64, rest: String)? {
        guard message.hasPrefix(prefix) else { return nil }
        let afterPrefix = message.dropFirst(prefix.count)
        let digits = afterPrefix.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int64(String(digits)) else { return nil }
        let remainder = afterPrefix.dropFirst(digits.count)
        guard remainder.hasPrefix(separator) else { return nil }
        return (number: number, rest: String(remainder.dropFirst(separator.count)))
    }

    /// Localized description for errors shown to the user. Core errors carry English text,
    /// so known cases are rebuilt here; system errors are already localized by macOS.
    static func describe(_ error: Error) -> String {
        if let storeError = error as? ConfigurationStoreError {
            if case .unsupportedSchema(let version) = storeError {
                return format("Configuration schema %lld is not supported. This app supports schema %lld.",
                              Int64(version), Int64(Configuration.currentSchemaVersion))
            }
            if case .fileTooLarge(let bytes) = storeError {
                return format("The configuration exceeds the %lld-byte file limit.", Int64(bytes))
            }
            if case .invalidConfiguration(let errors) = storeError {
                return errors.map { validationMessage($0) }.joined(separator: "\n")
            }
            if case .invalidFileURL = storeError { return text("Choose a local configuration file.") }
            if case .notRegularFile = storeError { return text("The configuration must be a regular file.") }
            return storeError.localizedDescription
        }
        if let leaseError = error as? ConfigurationLeaseError {
            if case .system(let code) = leaseError {
                return format("Could not acquire the configuration writer lease, POSIX error %lld.", Int64(code))
            }
            return text(leaseError.localizedDescription)
        }
        // Window geometry errors carry fixed English text, translated by exact lookup.
        if error is WindowLayoutError { return text(error.localizedDescription) }
        return error.localizedDescription
    }

    static var forcedLanguage: String? {
        let value = ProcessInfo.processInfo.environment["ACTIONFLOW_LANGUAGE"]
        return ["en", "zh-Hans"].contains(value ?? "") ? value : nil
    }
    static func text(_ key: String) -> String {
        if let bundle = languageBundle() { return bundle.localizedString(forKey: key, value: key, table: "Localizable") }
        return Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }
    private static func languageBundle() -> Bundle? {
        let language = forcedLanguage ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en")
        if let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) { return bundle }
        // Offscreen CLI harnesses have no app bundle. Only an explicit test environment
        // may point at source resources; production never scans the working directory.
        if let root = ProcessInfo.processInfo.environment["ACTIONFLOW_LOCALIZATION_ROOT"] {
            return Bundle(path: URL(fileURLWithPath: root).appendingPathComponent(language + ".lproj").path)
        }
        return nil
    }
}
