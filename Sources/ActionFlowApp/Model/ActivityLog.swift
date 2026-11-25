import Foundation

/// The bounded activity history. Newest entries come first.
struct ActivityLog {
    static let capacity = 200

    /// Inserts `entry` at the front and drops the oldest entries beyond `capacity`.
    static func prepend(_ entry: ActivityEntry, to entries: inout [ActivityEntry]) {
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }
}
