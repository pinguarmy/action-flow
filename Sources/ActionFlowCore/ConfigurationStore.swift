import Foundation
import Darwin

public enum ConfigurationStoreError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case fileTooLarge(maximumBytes: Int)
    case invalidConfiguration([String])
    case invalidFileURL
    case notRegularFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Configuration schema \(version) is not supported. This app supports schema \(Configuration.currentSchemaVersion)."
        case .fileTooLarge(let bytes):
            return "The configuration exceeds the \(bytes)-byte file limit."
        case .invalidConfiguration(let errors):
            return errors.joined(separator: "\n")
        case .invalidFileURL:
            return "Choose a local configuration file."
        case .notRegularFile:
            return "The configuration must be a regular file."
        }
    }
}

public struct ConfigurationSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let byteCount: Int
}

/// Local JSON persistence. Reading and importing never execute rules or change login settings.
public final class ConfigurationStore {
    public static let maximumFileBytes = 8 * 1_024 * 1_024
    public static let maximumSnapshots = 10
    private var historyURL: URL { url.appendingPathExtension("history") }
    public let url: URL
    public var backupURL: URL { url.appendingPathExtension("backup") }
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// A missing file yields safe defaults. Corrupt files throw and are never replaced on load.
    public func load() throws -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        try checkFileURL(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        return try decode(readBounded(url))
    }

    /// Validate and encode before touching either file. Preserve the exact previous bytes first.
    public func save(_ configuration: Configuration) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkFileURL(url)
        let data = try encode(configuration)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try readBounded(url)
            // A newer app may own this file. Even a valid replacement must not downgrade it.
            // A corrupt file can be replaced explicitly, but its exact bytes remain in the backup.
            if let header = try? JSONDecoder().decode(SchemaHeader.self, from: previous),
               header.schemaVersion != Configuration.currentSchemaVersion {
                throw ConfigurationStoreError.unsupportedSchema(header.schemaVersion)
            }
            try writePrivate(previous, to: backupURL)
        }
        try writePrivate(data, to: url)
    }

    /// Imports remain in memory until the caller explicitly saves them. All execution opt-ins reset.
    public func importConfiguration(from source: URL) throws -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        var configuration = try decode(readBounded(source))
        configuration.automationEnabled = false
        configuration.allowScripts = false
        configuration.launchAtLogin = false
        return configuration
    }

    /// Explicit recovery only. The backup remains untouched and every execution opt-in is reset.
    /// The exact replaced file, if present, is kept under a unique private recovery filename.
    public func restoreBackup() throws -> (configuration: Configuration, preservedCurrentFileURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        return try restoreConfiguration(from: readBounded(backupURL))
    }

    private func restoreConfiguration(from data: Data) throws -> (configuration: Configuration, preservedCurrentFileURL: URL?) {
        try checkFileURL(url)
        var configuration = try decode(data)
        configuration.automationEnabled = false
        configuration.allowScripts = false
        configuration.launchAtLogin = false
        for index in configuration.rules.indices { configuration.rules[index].enabled = false }
        let restoredData = try encode(configuration)

        var preservedURL: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try readBounded(url)
            if let header = try? JSONDecoder().decode(SchemaHeader.self, from: previous),
               header.schemaVersion != Configuration.currentSchemaVersion {
                throw ConfigurationStoreError.unsupportedSchema(header.schemaVersion)
            }
            let archive = url.appendingPathExtension("before-restore-\(UUID().uuidString)")
            // Unlike the rotating backup, an existing recovery archive must never be overwritten.
            try writePrivate(previous, to: archive, overwrite: false)
            preservedURL = archive
        }
        // Do not call save(): it would replace our recovery source with the corrupt current file.
        try writePrivate(restoredData, to: url)
        return (configuration: configuration, preservedCurrentFileURL: preservedURL)
    }

    /// Explicit snapshots retain the configuration as supplied, including its opt-ins, but run nothing.
    /// At capacity creation fails; this store never deletes or silently prunes user snapshots.
    public func createSnapshot(configuration: Configuration) throws -> ConfigurationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let data = try encode(configuration)
        return try withHistoryDirectory(create: true) { descriptor in
            guard let descriptor else { throw ConfigurationStoreError.notRegularFile }
            let existing = try snapshotMetadata(in: descriptor)
            guard existing.count < Self.maximumSnapshots else {
                throw ConfigurationStoreError.invalidConfiguration(["Snapshot history is full. The limit is 10 snapshots; no snapshots were deleted."])
            }
            let id = UUID().uuidString
            let name = id + ".json"
            try writePrivate(data, filename: name, directoryFD: descriptor, destination: historyURL.appendingPathComponent(name), overwrite: false)
            return try readSnapshotMetadata(name: name, directoryFD: descriptor)
        }
    }

    public func listSnapshots() throws -> [ConfigurationSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return try withHistoryDirectory(create: false) { descriptor in
            guard let descriptor else { return [] }
            return try snapshotMetadata(in: descriptor)
        }
    }

    public func restoreSnapshot(id: String) throws -> (configuration: Configuration, preservedCurrentFileURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        guard canonicalSnapshotID(id) else {
            throw ConfigurationStoreError.invalidConfiguration(["Choose a snapshot with a canonical UUID identifier."])
        }
        return try withHistoryDirectory(create: false) { descriptor in
            guard let descriptor else { throw fileOperationError(ENOENT, url: historyURL) }
            // Listing also refuses over-capacity directories and unsafe canonical entries.
            guard try snapshotMetadata(in: descriptor).contains(where: { $0.id == id }) else {
                throw fileOperationError(ENOENT, url: historyURL.appendingPathComponent(id + ".json"))
            }
            let data = try readSnapshot(name: id + ".json", directoryFD: descriptor)
            return try restoreConfiguration(from: data)
        }
    }

    public func exportConfiguration(_ configuration: Configuration, to destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkFileURL(destination)
        let data = try encode(configuration)
        // Resolve parent-directory aliases too: export must not bypass save/recovery safeguards.
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedLive = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedBackup = backupURL.resolvingSymlinksInPath().standardizedFileURL.path
        if resolvedDestination == resolvedLive {
            throw ConfigurationStoreError.invalidConfiguration(["Export to a different file so the live configuration remains unchanged."])
        }
        if resolvedDestination == resolvedBackup {
            throw ConfigurationStoreError.invalidConfiguration(["The backup file cannot be used as an export destination."])
        }
        let resolvedHistory = historyURL.resolvingSymlinksInPath().standardizedFileURL.path
        if resolvedDestination == resolvedHistory || resolvedDestination.hasPrefix(resolvedHistory + "/") {
            throw ConfigurationStoreError.invalidConfiguration(["Snapshot history cannot be used as an export destination."])
        }
        try writePrivate(data, to: destination)
    }

    private func canonicalSnapshotID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString == id
    }

    /// Pin a real private directory and serialize all cooperating processes using a private lock file.
    private func withHistoryDirectory<T>(create: Bool, _ body: (Int32?) throws -> T) throws -> T {
        try checkFileURL(url)
        let parent = historyURL.deletingLastPathComponent()
        if create { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let parentFD = parent.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard parentFD >= 0 else {
            if !create && errno == ENOENT { return try body(nil) }
            throw fileOperationError(errno, url: parent)
        }
        defer { Darwin.close(parentFD) }
        let name = historyURL.lastPathComponent
        if create {
            let result = name.withCString { Darwin.mkdirat(parentFD, $0, mode_t(0o700)) }
            if result != 0 && errno != EEXIST { throw fileOperationError(errno, url: historyURL) }
        }
        let descriptor = name.withCString {
            Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if !create && errno == ENOENT { return try body(nil) }
            throw fileOperationError(errno, url: historyURL)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw fileOperationError(errno, url: historyURL) }
        guard info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o077 == 0 else {
            throw ConfigurationStoreError.invalidConfiguration(["Snapshot history must be an owner-only directory, not a symbolic link or shared folder."])
        }
        guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else { throw fileOperationError(errno, url: historyURL) }
        let lockFD = Darwin.openat(descriptor, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard lockFD >= 0 else { throw fileOperationError(errno, url: historyURL) }
        defer { Darwin.close(lockFD) }
        var lockInfo = stat()
        guard Darwin.fstat(lockFD, &lockInfo) == 0 else { throw fileOperationError(errno, url: historyURL) }
        guard lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1 else {
            throw ConfigurationStoreError.notRegularFile
        }
        guard Darwin.fchmod(lockFD, mode_t(0o600)) == 0 else { throw fileOperationError(errno, url: historyURL) }
        // These synchronous APIs are used by the main actor. Never wait for another process.
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw ConfigurationStoreError.invalidConfiguration(["Snapshot history is busy. Try again after the other operation finishes."])
            }
            throw fileOperationError(errno, url: historyURL)
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        return try body(descriptor)
    }

    private func snapshotMetadata(in directoryFD: Int32) throws -> [ConfigurationSnapshot] {
        let duplicate = Darwin.dup(directoryFD)
        guard duplicate >= 0 else { throw fileOperationError(errno, url: historyURL) }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw fileOperationError(code, url: historyURL)
        }
        defer { Darwin.closedir(directory) }
        Darwin.rewinddir(directory)
        var snapshots: [ConfigurationSnapshot] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                if errno != 0 { throw fileOperationError(errno, url: historyURL) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".json"), canonicalSnapshotID(String(name.dropLast(5))) else { continue }
            guard snapshots.count < Self.maximumSnapshots else {
                throw ConfigurationStoreError.invalidConfiguration(["Snapshot history exceeds the 10-snapshot limit. No files were changed."])
            }
            snapshots.append(try readSnapshotMetadata(name: name, directoryFD: directoryFD))
        }
        return snapshots.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    private func openSnapshot(name: String, directoryFD: Int32) throws -> (descriptor: Int32, info: stat) {
        let source = historyURL.appendingPathComponent(name)
        let descriptor = name.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw fileOperationError(errno, url: source) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw fileOperationError(code, url: source)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor)
            throw ConfigurationStoreError.notRegularFile
        }
        guard info.st_size >= 0, info.st_size <= Self.maximumFileBytes else {
            Darwin.close(descriptor)
            throw ConfigurationStoreError.fileTooLarge(maximumBytes: Self.maximumFileBytes)
        }
        return (descriptor, info)
    }

    private func readSnapshotMetadata(name: String, directoryFD: Int32) throws -> ConfigurationSnapshot {
        let file = try openSnapshot(name: name, directoryFD: directoryFD)
        defer { Darwin.close(file.descriptor) }
        let timestamp = file.info.st_mtimespec
        return ConfigurationSnapshot(id: String(name.dropLast(5)),
                                     createdAt: Date(timeIntervalSince1970: Double(timestamp.tv_sec) + Double(timestamp.tv_nsec) / 1_000_000_000),
                                     byteCount: Int(file.info.st_size))
    }

    private func readSnapshot(name: String, directoryFD: Int32) throws -> Data {
        let file = try openSnapshot(name: name, directoryFD: directoryFD)
        let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return try readBounded(handle)
    }

    private func encode(_ configuration: Configuration) throws -> Data {
        try validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        guard data.count <= Self.maximumFileBytes else {
            throw ConfigurationStoreError.fileTooLarge(maximumBytes: Self.maximumFileBytes)
        }
        return data
    }

    private struct SchemaHeader: Decodable { var schemaVersion: Int }

    private func decode(_ data: Data) throws -> Configuration {
        let decoder = JSONDecoder()
        let header = try decoder.decode(SchemaHeader.self, from: data)
        guard header.schemaVersion == Configuration.currentSchemaVersion else {
            throw ConfigurationStoreError.unsupportedSchema(header.schemaVersion)
        }
        let configuration = try decoder.decode(Configuration.self, from: data)
        try validate(configuration)
        return configuration
    }

    private func validate(_ configuration: Configuration) throws {
        guard configuration.schemaVersion == Configuration.currentSchemaVersion else {
            throw ConfigurationStoreError.unsupportedSchema(configuration.schemaVersion)
        }
        guard configuration.rules.count <= RuleValidator.maximumRules else {
            throw ConfigurationStoreError.invalidConfiguration(["A configuration cannot have more than 1000 rules."])
        }
        var errors: [String] = []
        if Set(configuration.rules.map(\.id)).count != configuration.rules.count {
            errors.append("Rule identifiers must be unique.")
        }
        for (index, rule) in configuration.rules.enumerated() {
            let ruleErrors = rule.enabled ? RuleValidator.validate(rule) : RuleValidator.structuralErrors(rule)
            errors.append(contentsOf: ruleErrors.map { "Rule \(index + 1) (\(rule.name.prefix(80))): \($0)" })
        }
        if !errors.isEmpty { throw ConfigurationStoreError.invalidConfiguration(errors) }
    }

    private func readBounded(_ source: URL) throws -> Data {
        try checkFileURL(source)
        let resourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resourceValues.isRegularFile == true else { throw ConfigurationStoreError.notRegularFile }
        if let size = resourceValues.fileSize, size > Self.maximumFileBytes {
            throw ConfigurationStoreError.fileTooLarge(maximumBytes: Self.maximumFileBytes)
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        return try readBounded(handle)
    }

    private func readBounded(_ handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count <= Self.maximumFileBytes {
            let remaining = Self.maximumFileBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumFileBytes else {
            throw ConfigurationStoreError.fileTooLarge(maximumBytes: Self.maximumFileBytes)
        }
        return data
    }

    private func checkFileURL(_ candidate: URL) throws {
        guard candidate.isFileURL else { throw ConfigurationStoreError.invalidFileURL }
    }

    /// Stage private bytes beside the destination, then publish only a complete, synced file.
    /// Backup and live-file commits remain separate: a failed backup commit prevents the live write.
    private func writePrivate(_ data: Data, to destination: URL, overwrite: Bool = true) throws {
        try checkFileURL(destination)
        let directory = destination.deletingLastPathComponent()
        let filename = destination.lastPathComponent
        let directoryFD = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard directoryFD >= 0 else { throw fileOperationError(errno, url: directory) }
        defer { Darwin.close(directoryFD) }
        try writePrivate(data, filename: filename, directoryFD: directoryFD, destination: destination, overwrite: overwrite)
    }

    private func writePrivate(_ data: Data, filename: String, directoryFD: Int32, destination: URL, overwrite: Bool) throws {
        let temporaryName = ".actionflow-write-\(UUID().uuidString)"
        var descriptor = temporaryName.withCString {
            Darwin.openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw fileOperationError(errno, url: destination) }
        var identity = stat()
        let identified = Darwin.fstat(descriptor, &identity) == 0
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            // Never delete a substituted entry. The pinned directory and inode identify our file.
            if identified {
                var current = stat()
                let matches = temporaryName.withCString {
                    Darwin.fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
                        current.st_dev == identity.st_dev && current.st_ino == identity.st_ino
                }
                if matches {
                    _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
                }
            }
        }
        guard identified else { throw fileOperationError(errno, url: destination) }
        // Creation is at most 0600 even under umask 000; fix restrictive umasks before any data.
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw fileOperationError(errno, url: destination)
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw fileOperationError(errno, url: destination)
                }
                guard count > 0 else { throw fileOperationError(EIO, url: destination) }
                offset += count
            }
        }
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw fileOperationError(errno, url: destination)
        }
        let closeResult = Darwin.close(descriptor)
        let closeError = errno
        descriptor = -1 // close must not be retried; the descriptor may already have been reused.
        guard closeResult == 0 else { throw fileOperationError(closeError, url: destination) }

        let published = temporaryName.withCString { temporaryPath in
            filename.withCString { finalPath in
                if overwrite {
                    return Darwin.renameat(directoryFD, temporaryPath, directoryFD, finalPath)
                }
                // Publishing an archive by hard link is atomic and fails if its name exists.
                return Darwin.linkat(directoryFD, temporaryPath, directoryFD, finalPath, 0)
            }
        }
        guard published == 0 else { throw fileOperationError(errno, url: destination) }
        // No fallible operation follows publication. The defer only removes our staging link.
    }

    private func fileOperationError(_ code: Int32, url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
