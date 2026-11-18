import Foundation
import XCTest
@testable import ActionFlowCore

final class ConfigurationValidationTests: XCTestCase {
    /// The parent directory is never created: content validation fails before `save` touches the disk.
    private func unwrittenStore() -> ConfigurationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigurationValidationTests-\(UUID().uuidString)", isDirectory: true)
        return ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
    }

    private func assertSaveRejects(_ configuration: Configuration, with expected: ConfigurationStoreError,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let store = unwrittenStore()
        XCTAssertThrowsError(try store.save(configuration), file: file, line: line) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, expected, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), file: file, line: line)
    }

    func testValidConfigurationsHaveNoErrors() {
        XCTAssertEqual(ConfigurationStore.validationErrors(for: Configuration()), [])
        let enabled = Configuration(rules: [AutomationRule(name: "Valid", enabled: true)])
        XCTAssertEqual(ConfigurationStore.validationErrors(for: enabled), [])
        XCTAssertEqual(ConfigurationStore.validationErrors(for: Configuration(rules: [])), [])
    }

    func testEnabledRuleContentErrorsMatchSave() {
        let configuration = Configuration(rules: [AutomationRule(name: "", enabled: true)])
        let errors = ConfigurationStore.validationErrors(for: configuration)
        XCTAssertEqual(errors, ["Rule 1 (): Give this rule a name."])
        assertSaveRejects(configuration, with: .invalidConfiguration(errors))
    }

    func testDisabledRulesOnlyGetStructuralChecks() {
        let draft = Configuration(rules: [AutomationRule(name: "", enabled: false)])
        XCTAssertEqual(ConfigurationStore.validationErrors(for: draft), [])
        let oversized = Configuration(rules: [AutomationRule(name: String(repeating: "x", count: 257), enabled: false)])
        let errors = ConfigurationStore.validationErrors(for: oversized)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].hasPrefix("Rule 1 ("))
        XCTAssertTrue(errors[0].hasSuffix("): Rule names cannot exceed 256 bytes."))
        assertSaveRejects(oversized, with: .invalidConfiguration(errors))
    }

    func testDuplicateRuleIdentifiers() {
        let id = UUID()
        let configuration = Configuration(rules: [AutomationRule(id: id, name: "One"), AutomationRule(id: id, name: "Two")])
        let errors = ConfigurationStore.validationErrors(for: configuration)
        XCTAssertEqual(errors, ["Rule identifiers must be unique."])
        assertSaveRejects(configuration, with: .invalidConfiguration(errors))
    }

    func testUnsupportedSchemaAndRuleLimitMessages() {
        let future = Configuration(schemaVersion: 2, rules: [])
        XCTAssertEqual(ConfigurationStore.validationErrors(for: future),
                       [ConfigurationStoreError.unsupportedSchema(2).errorDescription ?? ""])
        assertSaveRejects(future, with: .unsupportedSchema(2))

        let tooMany = Configuration(rules: (0...RuleValidator.maximumRules).map { AutomationRule(name: "Rule \($0)") })
        XCTAssertEqual(ConfigurationStore.validationErrors(for: tooMany),
                       ["A configuration cannot have more than 1000 rules."])
        assertSaveRejects(tooMany, with: .invalidConfiguration(["A configuration cannot have more than 1000 rules."]))
    }
}
