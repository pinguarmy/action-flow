import Foundation
import XCTest
@testable import ActionFlowCore

final class ActionFlowCoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActionFlowCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private var store: ConfigurationStore {
        ConfigurationStore(url: temporaryDirectory.appendingPathComponent("configuration.json"))
    }

    func testDefaultsAndExamplesNeverEnableAutomationOrScripts() throws {
        let configuration = Configuration()
        XCTAssertFalse(configuration.automationEnabled)
        XCTAssertFalse(configuration.allowScripts)
        XCTAssertFalse(configuration.launchAtLogin)
        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertFalse(configuration.rules.isEmpty)
        for rule in configuration.rules {
            XCTAssertFalse(rule.enabled)
            XCTAssertTrue(RuleValidator.validate(rule).isEmpty, "Invalid sample: \(rule.name)")
        }
    }

    func testEveryModelRoundTripsThroughJSON() throws {
        for triggerKind in TriggerKind.allCases {
            for actionKind in ActionKind.allCases {
                let rule = AutomationRule(trigger: Trigger(kind: triggerKind), actions: [AutomationAction(kind: actionKind)])
                let data = try JSONEncoder().encode(rule)
                XCTAssertEqual(try JSONDecoder().decode(AutomationRule.self, from: data), rule)
            }
        }
        let modifiers: ModifierKeys = [.command, .option, .control, .shift]
        XCTAssertEqual(try JSONDecoder().decode(ModifierKeys.self, from: JSONEncoder().encode(modifiers)), modifiers)
        XCTAssertEqual(modifiers.displayString, "⌃⌥⇧⌘")
        XCTAssertEqual(ModifierKeys.command.rawValue, 1 << 20)
    }

    func testConditionsIncludeExcludeAndNormalizeIdentifiers() {
        let allApps = RuleConditions(excludedAppBundleIdentifiers: ["com.apple.Terminal"])
        XCTAssertTrue(allApps.matches(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(allApps.matches(bundleIdentifier: "com.apple.Terminal"))
        let specific = RuleConditions(appBundleIdentifiers: [" COM.APPLE.SAFARI "], excludedAppBundleIdentifiers: ["com.apple.Terminal"])
        XCTAssertTrue(specific.matches(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(specific.matches(bundleIdentifier: "com.apple.TextEdit"))
        XCTAssertFalse(specific.matches(bundleIdentifier: ""))
    }

    func testValidatorRequiresSafeShortcutAndActionChain() {
        var rule = AutomationRule()
        rule.name = " "
        rule.trigger.modifiers = [.shift]
        rule.trigger.keyCode = 128
        rule.actions = []
        let errors = RuleValidator.validate(rule)
        XCTAssertTrue(errors.contains(where: { $0.contains("name") }))
        XCTAssertTrue(errors.contains(where: { $0.contains("Command, Option, or Control") }))
        XCTAssertTrue(errors.contains(where: { $0.contains("Key code") }))
        XCTAssertTrue(errors.contains(where: { $0.contains("at least one action") }))
    }

    func testValidatorRejectsUnsafeURLSchemesAndAllowsWebAndMail() {
        for text in ["file:///etc/passwd", "javascript:alert(1)", "sh:command", "https://", "not a URL", "mailto:"] {
            let rule = AutomationRule(actions: [AutomationAction(kind: .openURL, text: text)])
            XCTAssertFalse(RuleValidator.validate(rule).isEmpty, "Accepted \(text)")
        }
        for text in ["https://example.com/path?q=test", "http://localhost:8080", "mailto:person@example.com"] {
            let rule = AutomationRule(actions: [AutomationAction(kind: .openURL, text: text)])
            XCTAssertTrue(RuleValidator.validate(rule).isEmpty, "Rejected \(text)")
        }
    }

    func testMailtoValidatesOpaqueRecipientsWithoutDependingOnURLPath() {
        let accepted = [
            "mailto:person@example.com",
            "MAILTO:person@example.com",
            "MailTo:person%40example.com?subject=Hello",
            "mailto:person%2Btag@example.com",
            "mailto:person@example.com,other%40example.com?body=Hello%20there"
        ]
        for text in accepted {
            let rule = AutomationRule(actions: [AutomationAction(kind: .openURL, text: text)])
            XCTAssertTrue(RuleValidator.validate(rule).isEmpty, "Rejected opaque mailto URI: \(text)")
        }
        let rejected = [
            "mailto:", "mailto:?subject=Hello", "MAILTO:?to=person@example.com",
            "mailto:#person@example.com", "mailto:person", "mailto:@example.com", "mailto:person@",
            "mailto:person%0A@example.com", "mailto:person%00@example.com",
            "mailto:%20?to=person@example.com", "mailto:person%ZZ@example.com",
            "mailto://person@example.com", "mailto:person@example.com,"
        ]
        for text in rejected {
            let rule = AutomationRule(actions: [AutomationAction(kind: .openURL, text: text)])
            XCTAssertFalse(RuleValidator.validate(rule).isEmpty, "Accepted invalid mailto URI: \(text)")
        }
    }

    func testValidatorBoundsTimingsAndRejectsNonFiniteValues() {
        for interval in [0.0, 0.9, 86_401, Double.infinity, Double.nan] {
            let rule = AutomationRule(trigger: Trigger(kind: .interval, intervalSeconds: interval))
            XCTAssertFalse(RuleValidator.validate(rule).isEmpty)
        }
        for interval in [1.0, 60, 86_400] {
            XCTAssertTrue(RuleValidator.validate(AutomationRule(trigger: Trigger(kind: .interval, intervalSeconds: interval))).isEmpty)
        }
        for delay in [-1.0, 61, Double.nan] {
            XCTAssertFalse(RuleValidator.validate(AutomationRule(actions: [AutomationAction(kind: .delay, delaySeconds: delay)])).isEmpty)
        }
        for cooldown in [-1.0, 86_401, Double.infinity] {
            XCTAssertFalse(RuleValidator.validate(AutomationRule(cooldown: cooldown)).isEmpty)
        }
    }

    func testValidatorBoundsMouseButtonsAndAppIdentifiers() {
        XCTAssertFalse(RuleValidator.validate(AutomationRule(trigger: Trigger(kind: .mouseButton, mouseButton: -1))).isEmpty)
        XCTAssertFalse(RuleValidator.validate(AutomationRule(trigger: Trigger(kind: .mouseButton, mouseButton: 32))).isEmpty)
        XCTAssertTrue(RuleValidator.validate(AutomationRule(trigger: Trigger(kind: .mouseButton, mouseButton: 2))).isEmpty)
        for identifier in ["", "Safari", "com..apple", "com.apple/Safari", " com.apple.Safari"] {
            XCTAssertFalse(RuleValidator.validate(AutomationRule(actions: [AutomationAction(kind: .launchApp, text: identifier)])).isEmpty)
        }
        XCTAssertTrue(RuleValidator.validate(AutomationRule(actions: [AutomationAction(kind: .launchApp, text: "com.apple.Safari")])).isEmpty)
    }

    func testValidatorDetectsImpossibleConditions() {
        let conditions = RuleConditions(appBundleIdentifiers: ["com.apple.Safari"], excludedAppBundleIdentifiers: ["com.apple.Safari"])
        XCTAssertTrue(RuleValidator.validate(AutomationRule(conditions: conditions)).contains(where: { $0.contains("every included app") }))
        let appRule = AutomationRule(trigger: Trigger(kind: .appActivated, appBundleIdentifier: "com.apple.Safari"),
                                     conditions: RuleConditions(appBundleIdentifiers: ["com.apple.Terminal"]))
        XCTAssertTrue(RuleValidator.validate(appRule).contains(where: { $0.contains("activation trigger") }))
    }

    func testConflictDetectionOnlyIncludesEnabledOverlappingTriggers() {
        var first = AutomationRule(name: "First", enabled: true)
        var second = AutomationRule(name: "Second", enabled: true)
        XCTAssertEqual(RuleValidator.conflicts(in: [first, second]).count, 1)
        second.enabled = false
        XCTAssertTrue(RuleValidator.conflicts(in: [first, second]).isEmpty)
        second.enabled = true
        second.trigger.keyCode = 1
        XCTAssertTrue(RuleValidator.conflicts(in: [first, second]).isEmpty)
        second.trigger = first.trigger
        first.conditions = RuleConditions(appBundleIdentifiers: ["com.apple.Safari"])
        second.conditions = RuleConditions(appBundleIdentifiers: ["com.apple.Terminal"])
        XCTAssertTrue(RuleValidator.conflicts(in: [first, second]).isEmpty)
        second.conditions = RuleConditions(excludedAppBundleIdentifiers: ["com.apple.Safari"])
        XCTAssertTrue(RuleValidator.conflicts(in: [first, second]).isEmpty)
        second.conditions = RuleConditions()
        XCTAssertEqual(RuleValidator.conflicts(in: [first, second]).count, 1)
    }

    func testConflictDetectionRespectsModifiersAndAppActivation() {
        var first = AutomationRule(name: "First", enabled: true, trigger: Trigger(kind: .mouseButton))
        var second = AutomationRule(name: "Second", enabled: true, trigger: Trigger(kind: .mouseButton, modifiers: [.command]))
        XCTAssertTrue(RuleValidator.conflicts(in: [first, second]).isEmpty)
        first.trigger = Trigger(kind: .appActivated, appBundleIdentifier: "com.apple.Safari")
        second.trigger = first.trigger
        XCTAssertEqual(RuleValidator.conflicts(in: [first, second]).count, 1)
        second.conditions.excludedAppBundleIdentifiers = ["com.apple.Safari"]
        XCTAssertTrue(RuleValidator.conflicts(in: [first, second]).isEmpty)
    }

    func testMissingConfigurationReturnsSafeDefaultsWithoutWriting() throws {
        let configuration = try store.load()
        XCTAssertFalse(configuration.automationEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testSaveLoadAndExactPreviousFileBackup() throws {
        let first = Configuration(rules: [AutomationRule(name: "First")])
        let second = Configuration(rules: [AutomationRule(name: "Second")], automationEnabled: true)
        try store.save(first)
        let previousBytes = try Data(contentsOf: store.url)
        try store.save(second)
        XCTAssertEqual(try store.load(), second)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), previousBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDisabledDraftCanSaveButEnabledInvalidRuleCannotOverwrite() throws {
        let draft = AutomationRule(name: "", actions: [])
        try store.save(Configuration(rules: [draft]))
        let originalBytes = try Data(contentsOf: store.url)
        XCTAssertEqual(try store.load().rules, [draft])
        var enabled = draft
        enabled.enabled = true
        XCTAssertThrowsError(try store.save(Configuration(rules: [enabled])))
        XCTAssertEqual(try Data(contentsOf: store.url), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
    }

    func testImportDisablesOptInsAndNeverWritesLiveConfiguration() throws {
        let live = Configuration(rules: [AutomationRule(name: "Live")])
        try store.save(live)
        let source = temporaryDirectory.appendingPathComponent("import.json")
        let imported = Configuration(rules: [AutomationRule(name: "Imported", enabled: true)],
                                     automationEnabled: true, allowScripts: true, launchAtLogin: true)
        try JSONEncoder().encode(imported).write(to: source)
        let result = try store.importConfiguration(from: source)
        XCTAssertFalse(result.automationEnabled)
        XCTAssertFalse(result.allowScripts)
        XCTAssertFalse(result.launchAtLogin)
        XCTAssertEqual(result.rules, imported.rules)
        XCTAssertEqual(try store.load(), live)
    }

    func testExportRoundTripsWithoutChangingLiveConfiguration() throws {
        let live = Configuration(rules: [AutomationRule(name: "Live")])
        try store.save(live)
        let exported = Configuration(rules: [AutomationRule(name: "Exported")])
        let destination = temporaryDirectory.appendingPathComponent("export.json")
        try store.exportConfiguration(exported, to: destination)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: destination)), exported)
        XCTAssertEqual(try store.load(), live)
        XCTAssertThrowsError(try store.exportConfiguration(exported, to: store.url))
        XCTAssertThrowsError(try store.exportConfiguration(exported, to: store.backupURL))
        XCTAssertEqual(try store.load(), live)
    }

    func testUnknownSchemaFailsBeforeDecodingRulesAndPreservesFile() throws {
        let data = Data("{\"schemaVersion\":999,\"rules\":\"a future shape\"}".utf8)
        try data.write(to: store.url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .unsupportedSchema(999))
        }
        XCTAssertEqual(try Data(contentsOf: store.url), data)
        XCTAssertThrowsError(try store.save(Configuration(schemaVersion: 999)))
        XCTAssertThrowsError(try store.save(Configuration())) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .unsupportedSchema(999))
        }
        XCTAssertEqual(try Data(contentsOf: store.url), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
    }

    func testCorruptFileIsNotOverwrittenOnLoadAndIsBackedUpOnExplicitSave() throws {
        let data = Data("not JSON".utf8)
        try data.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), data)
        try store.save(Configuration())
        XCTAssertEqual(try Data(contentsOf: store.backupURL), data)
        XCTAssertFalse(try store.load().automationEnabled)
    }

    func testMissingOptionalSettingsDecodeToSafeDefaults() throws {
        let data = Data("{\"schemaVersion\":1,\"rules\":[]}".utf8)
        try data.write(to: store.url)
        let loaded = try store.load()
        XCTAssertFalse(loaded.automationEnabled)
        XCTAssertFalse(loaded.allowScripts)
        XCTAssertFalse(loaded.launchAtLogin)
    }

    func testOversizedFileIsRejectedBeforeDecode() throws {
        let data = Data(repeating: 0x20, count: ConfigurationStore.maximumFileBytes + 1)
        let source = temporaryDirectory.appendingPathComponent("large.json")
        try data.write(to: source)
        XCTAssertThrowsError(try store.importConfiguration(from: source)) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .fileTooLarge(maximumBytes: ConfigurationStore.maximumFileBytes))
        }
    }

    func testDuplicateIDsAndStructuralLimitsAreRejectedForDisabledDrafts() throws {
        let rule = AutomationRule()
        XCTAssertThrowsError(try store.save(Configuration(rules: [rule, rule])))
        var duplicateActions = rule
        duplicateActions.actions = [rule.actions[0], rule.actions[0]]
        XCTAssertThrowsError(try store.save(Configuration(rules: [duplicateActions])))
        var longText = rule
        longText.actions = [AutomationAction(kind: .insertText, text: String(repeating: "x", count: RuleValidator.maximumTextBytes + 1))]
        XCTAssertThrowsError(try store.save(Configuration(rules: [longText])))
        let manyActions = AutomationRule(actions: (0...RuleValidator.maximumActionsPerRule).map { _ in AutomationAction() })
        XCTAssertThrowsError(try store.save(Configuration(rules: [manyActions])))
        let manyRules = (0...RuleValidator.maximumRules).map { _ in AutomationRule() }
        XCTAssertThrowsError(try store.save(Configuration(rules: manyRules)))
        let nonFinite = AutomationRule(cooldown: .nan)
        XCTAssertThrowsError(try store.save(Configuration(rules: [nonFinite])))
    }

    func testNonLocalAndDirectoryInputsAreRejected() throws {
        XCTAssertThrowsError(try ConfigurationStore(url: URL(string: "https://example.com/config.json")!).load())
        XCTAssertThrowsError(try store.importConfiguration(from: temporaryDirectory)) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .notRegularFile)
        }
    }

    func testRestoreBackupDisablesEveryRuleAndOptInAndPreservesBothSources() throws {
        let source = Configuration(rules: [AutomationRule(name: "Recovered", enabled: true)],
                                   automationEnabled: true, allowScripts: true, launchAtLogin: true)
        let backupBytes = try JSONEncoder().encode(source)
        let currentBytes = Data("damaged current configuration".utf8)
        try backupBytes.write(to: store.backupURL)
        try currentBytes.write(to: store.url)

        let restored = try store.restoreBackup()
        XCTAssertFalse(restored.configuration.automationEnabled)
        XCTAssertFalse(restored.configuration.allowScripts)
        XCTAssertFalse(restored.configuration.launchAtLogin)
        XCTAssertTrue(restored.configuration.rules.allSatisfy { !$0.enabled })
        XCTAssertEqual(restored.configuration.rules.map(\.id), source.rules.map(\.id))
        XCTAssertEqual(try store.load(), restored.configuration)
        let archive = try XCTUnwrap(restored.preservedCurrentFileURL)
        XCTAssertEqual(try Data(contentsOf: archive), currentBytes)
        XCTAssertTrue(archive.lastPathComponent.contains("before-restore-"))
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backupBytes)
        for file in [archive, store.url] {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let firstRestoredBytes = try Data(contentsOf: store.url)
        let second = try store.restoreBackup()
        XCTAssertNotEqual(second.preservedCurrentFileURL, archive)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(second.preservedCurrentFileURL)), firstRestoredBytes)
        XCTAssertEqual(try Data(contentsOf: archive), currentBytes)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backupBytes)
    }

    func testRestoreBackupWorksWhenCurrentFileIsMissing() throws {
        try JSONEncoder().encode(Configuration()).write(to: store.backupURL)
        let restored = try store.restoreBackup()
        XCTAssertNil(restored.preservedCurrentFileURL)
        XCTAssertEqual(try store.load(), restored.configuration)
    }

    func testRestoreRejectsMissingBackupWithoutChangingCurrentFile() throws {
        let current = Data("keep this current file".utf8)
        try current.write(to: store.url)
        XCTAssertThrowsError(try store.restoreBackup())
        XCTAssertEqual(try Data(contentsOf: store.url), current)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).count, 1)
    }

    func testRestoreRejectsInvalidBackupBeforeCreatingArchives() throws {
        let current = Data("keep this current file".utf8)
        try current.write(to: store.url)
        let invalidEnabledRule = Configuration(rules: [AutomationRule(name: "", enabled: true, actions: [])])
        let invalidSources = [Data("broken backup".utf8),
                              Data("{\"schemaVersion\":999,\"rules\":[]}".utf8),
                              try JSONEncoder().encode(invalidEnabledRule),
                              Data(repeating: 32, count: ConfigurationStore.maximumFileBytes + 1)]
        for source in invalidSources {
            try source.write(to: store.backupURL)
            XCTAssertThrowsError(try store.restoreBackup())
            XCTAssertEqual(try Data(contentsOf: store.url), current)
            XCTAssertEqual(try Data(contentsOf: store.backupURL), source)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).count, 2)
        }
    }

    func testRestoreNeverOverwritesFutureSchemaCurrentFile() throws {
        let future = Data("{\"schemaVersion\":999,\"rules\":\"future shape\"}".utf8)
        let backup = try JSONEncoder().encode(Configuration())
        try future.write(to: store.url)
        try backup.write(to: store.backupURL)
        XCTAssertThrowsError(try store.restoreBackup()) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .unsupportedSchema(999))
        }
        XCTAssertEqual(try Data(contentsOf: store.url), future)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).count, 2)
    }

    func testRestoreRejectsOversizedOrNonRegularCurrentFile() throws {
        let backup = try JSONEncoder().encode(Configuration())
        try backup.write(to: store.backupURL)
        let oversized = Data(repeating: 32, count: ConfigurationStore.maximumFileBytes + 1)
        try oversized.write(to: store.url)
        XCTAssertThrowsError(try store.restoreBackup())
        XCTAssertEqual(try Data(contentsOf: store.url), oversized)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
        let directoryStore = ConfigurationStore(url: temporaryDirectory.appendingPathComponent("directory-current"))
        try FileManager.default.createDirectory(at: directoryStore.url, withIntermediateDirectories: true)
        try backup.write(to: directoryStore.backupURL)
        XCTAssertThrowsError(try directoryStore.restoreBackup()) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .notRegularFile)
        }
        XCTAssertEqual(try Data(contentsOf: directoryStore.backupURL), backup)
    }

    func testPrivateWritesReplacePublicFilesWithPrivateInodes() throws {
        let first = Configuration(rules: [AutomationRule(name: "First")])
        let previous = try JSONEncoder().encode(first)
        try previous.write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        try store.save(Configuration(rules: [AutomationRule(name: "Second")]))
        let exported = temporaryDirectory.appendingPathComponent("public-export.json")
        try Data("old export".utf8).write(to: exported)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exported.path)
        try store.exportConfiguration(first, to: exported)
        for file in [store.url, store.backupURL, exported] {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual(try Data(contentsOf: store.backupURL), previous)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .contains(where: { $0.hasPrefix(".actionflow-write-") }))
    }

    func testFailedBackupPublicationLeavesLiveFileAndUnrelatedEntriesUntouched() throws {
        try store.save(Configuration(rules: [AutomationRule(name: "Original")]))
        let original = try Data(contentsOf: store.url)
        // A nonempty directory makes atomic rename fail without relying on root permissions.
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: true)
        let sentinel = store.backupURL.appendingPathComponent("keep-me")
        let sentinelBytes = Data("unrelated bytes".utf8)
        try sentinelBytes.write(to: sentinel)
        let lookalike = temporaryDirectory.appendingPathComponent(".actionflow-write-not-ours")
        try sentinelBytes.write(to: lookalike)
        XCTAssertThrowsError(try store.save(Configuration(rules: [AutomationRule(name: "Replacement")])))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertEqual(try Data(contentsOf: lookalike), sentinelBytes)
        let stagingNames = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".actionflow-write-") }
        XCTAssertEqual(stagingNames, [lookalike.lastPathComponent])
    }

    func testFailedExportPublicationCleansStagingAndPreservesDestinationDirectory() throws {
        let destination = temporaryDirectory.appendingPathComponent("export-directory")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("keep-me")
        try Data("preserved".utf8).write(to: sentinel)
        XCTAssertThrowsError(try store.exportConfiguration(Configuration(), to: destination))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserved".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .contains(where: { $0.hasPrefix(".actionflow-write-") }))
    }

    func testSummariesHaveReadableNamesWithoutLeakingScripts() {
        XCTAssertEqual(Trigger(keyCode: 123).summary, "⌃⌥←")
        XCTAssertEqual(AutomationAction(windowOperation: .leftHalf).summary, "Left half")
        XCTAssertFalse(AutomationAction(kind: .shellScript, text: "secret command").summary.contains("secret"))
        XCTAssertEqual(KeyCodeLabel.label(for: 65535), "Key 65535")
    }
}
