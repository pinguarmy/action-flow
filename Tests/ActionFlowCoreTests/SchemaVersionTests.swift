import Foundation
import XCTest
@testable import ActionFlowCore

/// Schema 2 adds window layouts. Files are written with the oldest schema that can represent them,
/// so configurations without the new layouts stay readable by older app versions.
final class SchemaVersionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("actionflow-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private var store: ConfigurationStore {
        ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
    }

    private func thirdsConfiguration() -> Configuration {
        Configuration(rules: [AutomationRule(name: "Third", actions: [AutomationAction(windowOperation: .leftThird)])])
    }

    private func declaredVersion(of url: URL) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(object?["schemaVersion"] as? Int)
    }

    func testVersionConstantsAndMinimumRule() {
        XCTAssertEqual(Configuration.currentSchemaVersion, 2)
        XCTAssertEqual(Configuration.supportedSchemaVersions, 1...2)
        XCTAssertEqual(Configuration().schemaVersion, Configuration.currentSchemaVersion)
        XCTAssertEqual(Configuration().minimumSchemaVersion, 1)
        XCTAssertEqual(Configuration(rules: []).minimumSchemaVersion, 1)
        XCTAssertEqual(thirdsConfiguration().minimumSchemaVersion, 2)
        // Every operation counts, even on an action whose kind never uses it, because it is serialized.
        let hidden = AutomationAction(kind: .notification, text: "x", windowOperation: .previousDisplay)
        XCTAssertEqual(Configuration(rules: [AutomationRule(actions: [hidden])]).minimumSchemaVersion, 2)
        XCTAssertEqual(thirdsConfiguration().withMinimumSchemaVersion().schemaVersion, 2)
        XCTAssertEqual(Configuration().withMinimumSchemaVersion().schemaVersion, 1)
    }

    func testDefaultConfigurationIsWrittenAsSchemaOneAndLoadsEqual() throws {
        let configuration = Configuration()
        try store.save(configuration)
        XCTAssertEqual(try declaredVersion(of: store.url), 1)
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(try store.load().schemaVersion, Configuration.currentSchemaVersion)
        let loaded = try store.loadWithDeclaredSchemaVersion()
        XCTAssertEqual(loaded.configuration, configuration)
        XCTAssertEqual(loaded.declaredSchemaVersion, 1)
    }

    func testNewLayoutConfigurationIsWrittenAsSchemaTwoAndLoadsEqual() throws {
        let configuration = thirdsConfiguration()
        try store.save(configuration)
        XCTAssertEqual(try declaredVersion(of: store.url), 2)
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(try store.loadWithDeclaredSchemaVersion().declaredSchemaVersion, 2)
        // Saving again over a schema 2 file is allowed and the version follows the content.
        try store.save(Configuration())
        XCTAssertEqual(try declaredVersion(of: store.url), 1)
        XCTAssertEqual(try declaredVersion(of: store.backupURL), 2)
    }

    func testSchemaOneFileWithNewLayoutIsRejectedWithFixedMessage() throws {
        let source = directory.appendingPathComponent("source.json")
        try store.exportConfiguration(thirdsConfiguration(), to: source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        object["schemaVersion"] = 1
        let downgraded = try JSONSerialization.data(withJSONObject: object)
        try downgraded.write(to: store.url)
        let expected = ConfigurationStoreError.invalidConfiguration([ConfigurationStore.layoutSchemaMismatchMessage])
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? ConfigurationStoreError, expected) }
        XCTAssertThrowsError(try store.loadWithDeclaredSchemaVersion()) { XCTAssertEqual($0 as? ConfigurationStoreError, expected) }
        XCTAssertThrowsError(try store.importConfiguration(from: store.url)) { XCTAssertEqual($0 as? ConfigurationStoreError, expected) }
        XCTAssertEqual(ConfigurationStore.layoutSchemaMismatchMessage,
                       "This configuration uses window layouts that need schema 2, but the file declares schema 1.")
        XCTAssertEqual(try Data(contentsOf: store.url), downgraded)
    }

    func testSchemaTwoFileWithoutNewLayoutsLoadsAndResavesAsSchemaOne() throws {
        let data = Data("{\"schemaVersion\":2,\"rules\":[]}".utf8)
        try data.write(to: store.url)
        let loaded = try store.load()
        XCTAssertEqual(loaded.schemaVersion, Configuration.currentSchemaVersion)
        XCTAssertEqual(try store.loadWithDeclaredSchemaVersion().declaredSchemaVersion, 2)
        try store.save(loaded)
        XCTAssertEqual(try declaredVersion(of: store.url), 1)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), data)
        XCTAssertEqual(try store.load(), loaded)
    }

    func testSchemaOneFileIsReplacedNormallyAndKeepsValidBackup() throws {
        let schemaOne = Data("{\"schemaVersion\":1,\"rules\":[]}".utf8)
        try schemaOne.write(to: store.url)
        try Data("older backup".utf8).write(to: store.backupURL)
        // A valid schema 1 file counts as valid content, so a non-rotating save keeps the older backup.
        try store.save(thirdsConfiguration(), rotatingBackup: false)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), Data("older backup".utf8))
        XCTAssertEqual(try declaredVersion(of: store.url), 2)
        // The schema 2 file just written is valid current content too.
        try store.save(Configuration(), rotatingBackup: false)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), Data("older backup".utf8))
        // The default save always rotates.
        try schemaOne.write(to: store.url)
        try store.save(Configuration())
        XCTAssertEqual(try Data(contentsOf: store.backupURL), schemaOne)
    }

    func testNewerSchemaIsRefusedAndNeverOverwritten() throws {
        let future = Data("{\"schemaVersion\":3,\"rules\":\"future shape\"}".utf8)
        try future.write(to: store.url)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? ConfigurationStoreError, .unsupportedSchema(3)) }
        for configuration in [Configuration(), thirdsConfiguration()] {
            XCTAssertThrowsError(try store.save(configuration)) { XCTAssertEqual($0 as? ConfigurationStoreError, .unsupportedSchema(3)) }
        }
        XCTAssertEqual(try Data(contentsOf: store.url), future)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
        try JSONEncoder().encode(Configuration()).write(to: store.backupURL)
        XCTAssertThrowsError(try store.restoreBackup()) { XCTAssertEqual($0 as? ConfigurationStoreError, .unsupportedSchema(3)) }
        XCTAssertEqual(try Data(contentsOf: store.url), future)
    }

    func testExportWritesMinimumVersion() throws {
        let plain = directory.appendingPathComponent("plain.json")
        let thirds = directory.appendingPathComponent("thirds.json")
        let plainConfiguration = Configuration()
        let thirdsConfig = thirdsConfiguration()
        try store.exportConfiguration(plainConfiguration, to: plain)
        try store.exportConfiguration(thirdsConfig, to: thirds)
        XCTAssertEqual(try declaredVersion(of: plain), 1)
        XCTAssertEqual(try declaredVersion(of: thirds), 2)
        XCTAssertEqual(try store.importConfiguration(from: plain), plainConfiguration)
        XCTAssertEqual(try store.importConfiguration(from: thirds), thirdsConfig)
        XCTAssertEqual(try store.importConfiguration(from: thirds).schemaVersion, Configuration.currentSchemaVersion)
    }

    func testSnapshotsAndRestoreKeepWorkingAcrossVersions() throws {
        var plain = Configuration()
        plain.automationEnabled = true
        let thirds = thirdsConfiguration()
        let first = try store.createSnapshot(configuration: plain)
        let second = try store.createSnapshot(configuration: thirds)
        let history = directory.appendingPathComponent("configuration.json.history")
        XCTAssertEqual(try declaredVersion(of: history.appendingPathComponent(first.id + ".json")), 1)
        XCTAssertEqual(try declaredVersion(of: history.appendingPathComponent(second.id + ".json")), 2)
        let restoredThirds = try store.restoreSnapshot(id: second.id)
        XCTAssertEqual(restoredThirds.configuration.rules, thirds.rules)
        XCTAssertEqual(try declaredVersion(of: store.url), 2)
        let restoredPlain = try store.restoreSnapshot(id: first.id)
        XCTAssertFalse(restoredPlain.configuration.automationEnabled)
        XCTAssertEqual(try declaredVersion(of: store.url), 1)
        XCTAssertEqual(try store.load(), restoredPlain.configuration)
    }

    func testPlainDecoderNormalizesSupportedVersionsAndKeepsUnsupportedOnes() throws {
        for version in [1, 2] {
            let data = Data("{\"schemaVersion\":\(version),\"rules\":[]}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: data).schemaVersion, Configuration.currentSchemaVersion)
        }
        let future = Data("{\"schemaVersion\":3,\"rules\":[]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: future).schemaVersion, 3)
    }

    func testEveryNewOperationRoundTripsThroughTheStore() throws {
        let operations: [WindowOperation] = [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds, .previousDisplay]
        let rules = operations.map { AutomationRule(name: $0.rawValue, actions: [AutomationAction(windowOperation: $0)]) }
        let configuration = Configuration(rules: rules)
        try store.save(configuration)
        XCTAssertEqual(try store.load().rules.map { $0.actions[0].windowOperation }, operations)
    }
}
