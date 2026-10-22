import Foundation

/// Uses installed resources, with an explicit test-only locale override.
/// Unknown/user-provided strings are returned unchanged.
enum AppLocalization {
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
