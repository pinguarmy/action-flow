import Foundation
import XCTest
@testable import ActionFlowCore

final class ConfigurationLeaseTests: XCTestCase {
    private var root: URL!
    private var configurationURL: URL { root.appendingPathComponent("private/configuration.json") }
    private var lockURL: URL { configurationURL.appendingPathExtension("writer-lock") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GFLeaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSecondLeaseFailsImmediatelyAndCanAcquireAfterRelease() throws {
        let first = try ConfigurationLease(configurationURL: configurationURL)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ConfigurationLease(configurationURL: configurationURL)) {
            XCTAssertEqual($0 as? ConfigurationLeaseError, .busy)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        first.release()
        first.release()
        let second = try ConfigurationLease(configurationURL: configurationURL)
        XCTAssertThrowsError(try ConfigurationLease(configurationURL: configurationURL)) {
            XCTAssertEqual($0 as? ConfigurationLeaseError, .busy)
        }
        second.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testDeinitReleasesLeaseWithoutRemovingLockOrChangingItsInode() throws {
        var lease: ConfigurationLease? = try ConfigurationLease(configurationURL: configurationURL)
        let before = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertNotNil(lease)
        lease = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        let next = try ConfigurationLease(configurationURL: configurationURL)
        defer { next.release() }
        let after = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try Data(contentsOf: lockURL), Data())
    }

    func testAcquisitionCreatesPrivateParentAndLockButNotLiveConfiguration() throws {
        let lease = try ConfigurationLease(configurationURL: configurationURL)
        defer { lease.release() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationURL.path))
        for (url, mode) in [(configurationURL.deletingLastPathComponent(), 0o700), (lockURL, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
        XCTAssertEqual(try Data(contentsOf: lockURL).count, 0)
    }

    func testExistingConfigurationAndLockContentsAreNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = Data("existing configuration bytes".utf8)
        let lockContents = Data("existing lock marker".utf8)
        try current.write(to: configurationURL)
        try lockContents.write(to: lockURL)
        let lease = try ConfigurationLease(configurationURL: configurationURL)
        lease.release()
        XCTAssertEqual(try Data(contentsOf: configurationURL), current)
        XCTAssertEqual(try Data(contentsOf: lockURL), lockContents)
    }

    func testParentDirectoryAliasContendsForSamePhysicalLock() throws {
        let first = try ConfigurationLease(configurationURL: configurationURL)
        defer { first.release() }
        let alias = root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: configurationURL.deletingLastPathComponent())
        let aliasedURL = alias.appendingPathComponent(configurationURL.lastPathComponent)
        XCTAssertThrowsError(try ConfigurationLease(configurationURL: aliasedURL)) {
            XCTAssertEqual($0 as? ConfigurationLeaseError, .busy)
        }
    }

    func testSymbolicAndHardLinkedLockFilesAreRejectedWithoutChangingTargets() throws {
        try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("unrelated-file")
        let original = Data("do not alter this target".utf8)
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: outside)
        XCTAssertThrowsError(try ConfigurationLease(configurationURL: configurationURL)) {
            XCTAssertEqual($0 as? ConfigurationLeaseError, .unsafeFile)
        }
        XCTAssertEqual(try Data(contentsOf: outside), original)
        let hardLinkedConfiguration = root.appendingPathComponent("hardlink-config.json")
        try FileManager.default.linkItem(at: outside, to: hardLinkedConfiguration.appendingPathExtension("writer-lock"))
        XCTAssertThrowsError(try ConfigurationLease(configurationURL: hardLinkedConfiguration)) {
            XCTAssertEqual($0 as? ConfigurationLeaseError, .unsafeFile)
        }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testDirectoryLockAndRemoteConfigurationURLAreRejected() throws {
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ConfigurationLease(configurationURL: configurationURL))
        XCTAssertThrowsError(try ConfigurationLease(configurationURL: URL(string: "https://example.com/private.json")!)) {
            XCTAssertEqual($0 as? ConfigurationLeaseError, .invalidURL)
        }
    }

    func testRepeatedConcurrentReleaseDoesNotReleaseANewLeasesDescriptor() throws {
        let first = try ConfigurationLease(configurationURL: configurationURL)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in first.release() }
        let second = try ConfigurationLease(configurationURL: configurationURL)
        defer { second.release() }
        first.release()
        XCTAssertThrowsError(try ConfigurationLease(configurationURL: configurationURL)) {
            XCTAssertEqual($0 as? ConfigurationLeaseError, .busy)
        }
    }
}
