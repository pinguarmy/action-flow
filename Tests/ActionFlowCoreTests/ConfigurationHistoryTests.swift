import Foundation
import Darwin
import XCTest
@testable import ActionFlowCore

final class ConfigurationHistoryTests: XCTestCase {
    private var root: URL!
    private var store: ConfigurationStore!
    private var history: URL { store.url.appendingPathExtension("history") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GFHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func snapshotFile(_ snapshot: ConfigurationSnapshot) -> URL {
        history.appendingPathComponent(snapshot.id + ".json")
    }

    func testExplicitSnapshotRetainsConfigurationWithoutWritingLiveFile() throws {
        XCTAssertTrue(try store.listSnapshots().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        let source = Configuration(rules: [AutomationRule(enabled: true)], automationEnabled: true, allowScripts: true, launchAtLogin: true)
        let snapshot = try store.createSnapshot(configuration: source)
        let bytes = try Data(contentsOf: snapshotFile(snapshot))
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: bytes), source)
        XCTAssertEqual(snapshot.byteCount, bytes.count)
        XCTAssertEqual(UUID(uuidString: snapshot.id)?.uuidString, snapshot.id)
        XCTAssertEqual(try store.listSnapshots(), [snapshot])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        for (url, mode) in [(history, 0o700), (snapshotFile(snapshot), 0o600), (history.appendingPathComponent(".lock"), 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
    }

    func testHistoryStopsAtTenAndNeverDeletesExistingSnapshots() throws {
        var originals: [String: Data] = [:]
        for _ in 0..<10 {
            let snapshot = try store.createSnapshot(configuration: Configuration())
            originals[snapshot.id] = try Data(contentsOf: snapshotFile(snapshot))
        }
        XCTAssertThrowsError(try store.createSnapshot(configuration: Configuration()))
        let snapshots = try store.listSnapshots()
        XCTAssertEqual(snapshots.count, 10)
        for snapshot in snapshots { XCTAssertEqual(try Data(contentsOf: snapshotFile(snapshot)), originals[snapshot.id]) }
        XCTAssertEqual(snapshots.map(\.createdAt), snapshots.map(\.createdAt).sorted(by: >))
    }

    func testRestoreDisablesAllExecutionAndPreservesExactCurrentAndSnapshot() throws {
        let source = Configuration(rules: [AutomationRule(enabled: true)], automationEnabled: true, allowScripts: true, launchAtLogin: true)
        let snapshot = try store.createSnapshot(configuration: source)
        let snapshotBytes = try Data(contentsOf: snapshotFile(snapshot))
        let corrupt = Data("damaged live file".utf8)
        let backup = Data("unchanged rotating backup".utf8)
        try corrupt.write(to: store.url)
        try backup.write(to: store.backupURL)
        let restored = try store.restoreSnapshot(id: snapshot.id)
        XCTAssertFalse(restored.configuration.automationEnabled)
        XCTAssertFalse(restored.configuration.allowScripts)
        XCTAssertFalse(restored.configuration.launchAtLogin)
        XCTAssertTrue(restored.configuration.rules.allSatisfy { !$0.enabled })
        XCTAssertEqual(try store.load(), restored.configuration)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.preservedCurrentFileURL)), corrupt)
        XCTAssertEqual(try Data(contentsOf: snapshotFile(snapshot)), snapshotBytes)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
        let second = try store.restoreSnapshot(id: snapshot.id)
        XCTAssertNotEqual(restored.preservedCurrentFileURL, second.preservedCurrentFileURL)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.preservedCurrentFileURL)), corrupt)
    }

    func testRestoreWithMissingCurrentAndFutureSchemaProtection() throws {
        let snapshot = try store.createSnapshot(configuration: Configuration())
        XCTAssertNil(try store.restoreSnapshot(id: snapshot.id).preservedCurrentFileURL)
        let future = Data("{\"schemaVersion\":999,\"rules\":[]}".utf8)
        try future.write(to: store.url)
        XCTAssertThrowsError(try store.restoreSnapshot(id: snapshot.id)) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .unsupportedSchema(999))
        }
        XCTAssertEqual(try Data(contentsOf: store.url), future)
    }

    func testInvalidIDsAndUnknownNamesCannotEscapeHistory() throws {
        let snapshot = try store.createSnapshot(configuration: Configuration())
        let unrelated = history.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: history.appendingPathComponent("ignored-link"), withDestinationURL: store.url)
        XCTAssertEqual(try store.listSnapshots().count, 1)
        for id in ["../configuration", snapshot.id + ".json", snapshot.id.lowercased(), "/tmp/escape", UUID().uuidString] {
            XCTAssertThrowsError(try store.restoreSnapshot(id: id))
        }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep me".utf8))
    }

    func testSymlinkHistoryDirectoryAndSharedDirectoryAreRejected() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: outside)
        XCTAssertThrowsError(try store.listSnapshots())
        XCTAssertThrowsError(try store.createSnapshot(configuration: Configuration()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let sharedStore = ConfigurationStore(url: root.appendingPathComponent("shared.json"))
        let shared = sharedStore.url.appendingPathExtension("history")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try sharedStore.listSnapshots())
    }

    func testCanonicalSymlinkSnapshotAndSymlinkLockAreRejected() throws {
        let snapshot = try store.createSnapshot(configuration: Configuration())
        let outside = root.appendingPathComponent("outside-secret")
        let secret = Data("private bytes".utf8)
        try secret.write(to: outside)
        let fake = history.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: fake, withDestinationURL: outside)
        XCTAssertThrowsError(try store.listSnapshots())
        XCTAssertThrowsError(try store.restoreSnapshot(id: String(fake.lastPathComponent.dropLast(5))))
        XCTAssertEqual(try Data(contentsOf: outside), secret)
        let otherStore = ConfigurationStore(url: root.appendingPathComponent("lock-test.json"))
        let otherHistory = otherStore.url.appendingPathExtension("history")
        try FileManager.default.createDirectory(at: otherHistory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: otherHistory.appendingPathComponent(".lock"), withDestinationURL: outside)
        XCTAssertThrowsError(try otherStore.createSnapshot(configuration: Configuration()))
        XCTAssertEqual(try Data(contentsOf: outside), secret)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotFile(snapshot).path))
    }

    func testOversizedAndCorruptSnapshotsFailWithoutChangingLiveFile() throws {
        let snapshot = try store.createSnapshot(configuration: Configuration())
        let current = Data("keep current".utf8)
        try current.write(to: store.url)
        for bytes in [Data("invalid JSON".utf8), Data("{\"schemaVersion\":999,\"rules\":[]}".utf8),
                      Data(repeating: 32, count: ConfigurationStore.maximumFileBytes + 1)] {
            try bytes.write(to: snapshotFile(snapshot))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotFile(snapshot).path)
            XCTAssertThrowsError(try store.restoreSnapshot(id: snapshot.id))
            XCTAssertEqual(try Data(contentsOf: store.url), current)
        }
    }

    func testExportsCannotOverwriteSnapshotsDirectlyOrThroughDirectoryAlias() throws {
        let snapshot = try store.createSnapshot(configuration: Configuration())
        let bytes = try Data(contentsOf: snapshotFile(snapshot))
        XCTAssertThrowsError(try store.exportConfiguration(Configuration(rules: []), to: snapshotFile(snapshot)))
        let alias = root.appendingPathComponent("history-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: history)
        XCTAssertThrowsError(try store.exportConfiguration(Configuration(rules: []), to: alias.appendingPathComponent(snapshot.id + ".json")))
        XCTAssertEqual(try Data(contentsOf: snapshotFile(snapshot)), bytes)
    }

    func testHeldHistoryLockFailsImmediatelyWithoutTouchingCurrentOrSnapshot() throws {
        let snapshot = try store.createSnapshot(configuration: Configuration())
        let snapshotBytes = try Data(contentsOf: snapshotFile(snapshot))
        let live = Data("keep current configuration".utf8)
        try live.write(to: store.url)
        let lockURL = history.appendingPathComponent(".lock")
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDWR | O_CLOEXEC) } ?? -1
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(descriptor, LOCK_UN) }
        let expected = ConfigurationStoreError.invalidConfiguration([
            "Snapshot history is busy. Try again after the other operation finishes."
        ])
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try store.listSnapshots()) { XCTAssertEqual($0 as? ConfigurationStoreError, expected) }
        XCTAssertThrowsError(try store.createSnapshot(configuration: Configuration())) { XCTAssertEqual($0 as? ConfigurationStoreError, expected) }
        XCTAssertThrowsError(try store.restoreSnapshot(id: snapshot.id)) { XCTAssertEqual($0 as? ConfigurationStoreError, expected) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertEqual(try Data(contentsOf: store.url), live)
        XCTAssertEqual(try Data(contentsOf: snapshotFile(snapshot)), snapshotBytes)
    }

    func testExportsThroughParentAliasCannotReplaceFutureLiveOrBackup() throws {
        let future = Data("{\"schemaVersion\":999,\"rules\":\"future shape\"}".utf8)
        let backup = Data("preserved backup bytes".utf8)
        try future.write(to: store.url)
        try backup.write(to: store.backupURL)
        let alias = root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try store.exportConfiguration(Configuration(), to: alias.appendingPathComponent(store.url.lastPathComponent)))
        XCTAssertThrowsError(try store.exportConfiguration(Configuration(), to: alias.appendingPathComponent(store.backupURL.lastPathComponent)))
        XCTAssertEqual(try Data(contentsOf: store.url), future)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
        // An ordinary sibling export through the same alias must remain supported.
        let sibling = alias.appendingPathComponent("exported-copy.json")
        try store.exportConfiguration(Configuration(rules: []), to: sibling)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: sibling)).rules, [])
        XCTAssertEqual(try Data(contentsOf: store.url), future)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
    }

    func testInvalidConfigurationCreatesNoHistoryDirectory() throws {
        XCTAssertThrowsError(try store.createSnapshot(configuration: Configuration(schemaVersion: 999)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
    }
}
