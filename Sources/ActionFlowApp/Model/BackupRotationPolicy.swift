import Foundation

/// Decides when a configuration write rotates the recovery backup.
///
/// Edits autosave shortly after each pause, so rotating the recovery backup on every write would
/// leave it only one typing burst old. Rotate on the first write of this app session, then at most
/// every 10 minutes; imports and templates always rotate (`forced`). The backup
/// therefore holds the configuration from before the current editing session (or from at most
/// ~10 minutes of edits ago), or from just before the last import or template. Restores never
/// touch the backup. The store still rotates whenever the previous file is unreadable or no backup
/// exists yet, so damaged bytes are always preserved.
struct BackupRotationPolicy {
    static let interval: TimeInterval = 10 * 60

    /// System uptime of the last write that rotated the recovery backup in this app session.
    private var lastRotation: TimeInterval?

    func shouldRotate(now: TimeInterval, forced: Bool) -> Bool {
        var rotate = forced
        if let last = lastRotation {
            if now - last >= Self.interval { rotate = true }
        } else {
            rotate = true
        }
        return rotate
    }

    /// Call after a write that rotated the backup succeeded.
    mutating func recordRotation(at now: TimeInterval) {
        lastRotation = now
    }
}
