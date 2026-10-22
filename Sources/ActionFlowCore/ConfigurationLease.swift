import Foundation
import Darwin

public enum ConfigurationLeaseError: Error, LocalizedError, Equatable, Sendable {
    case busy
    case unsafeFile
    case invalidURL
    case system(Int32)

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "Another ActionFlow instance holds the configuration writer lease. This instance is read-only."
        case .unsafeFile:
            return "The configuration writer lock must be a private regular file owned by the current user, not a symbolic or hard link."
        case .invalidURL:
            return "The configuration writer lease requires a local file URL."
        case .system(let code):
            return "Could not acquire the configuration writer lease, POSIX error \(code)."
        }
    }
}

/// A lifetime, cooperative single-writer lease. It never reads or writes configuration contents.
/// The stable lock file is never removed, so later instances cannot lock a replacement inode.
public final class ConfigurationLease {
    private let stateLock = NSLock()
    private var descriptor: Int32

    public init(configurationURL: URL) throws {
        guard configurationURL.isFileURL else { throw ConfigurationLeaseError.invalidURL }
        let lockURL = configurationURL.appendingPathExtension("writer-lock")
        let parent = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = parent.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard directoryFD >= 0 else { throw ConfigurationLeaseError.system(errno) }
        defer { Darwin.close(directoryFD) }
        let file = lockURL.lastPathComponent.withCString {
            Darwin.openat(directoryFD, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        }
        guard file >= 0 else {
            let code = errno
            if code == ELOOP { throw ConfigurationLeaseError.unsafeFile }
            throw ConfigurationLeaseError.system(code)
        }
        var acquired = false
        defer { if !acquired { Darwin.close(file) } }
        var info = stat()
        guard Darwin.fstat(file, &info) == 0 else { throw ConfigurationLeaseError.system(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_nlink == 1 else {
            throw ConfigurationLeaseError.unsafeFile
        }
        guard Darwin.fchmod(file, mode_t(0o600)) == 0 else { throw ConfigurationLeaseError.system(errno) }
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN { throw ConfigurationLeaseError.busy }
            throw ConfigurationLeaseError.system(code)
        }
        descriptor = file
        acquired = true
    }

    /// Release only this descriptor's lease. Closing never deletes the shared lock file.
    public func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        let file = descriptor
        descriptor = -1
        _ = flock(file, LOCK_UN)
        _ = Darwin.close(file)
    }

    deinit { release() }
}
