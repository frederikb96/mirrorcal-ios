/// A summary of one applied plan, in the shape a log line or a debug-bridge response wants. Every
/// run produces one of these — including a coalesced or skipped run — because the Android app's
/// silently-dropped syncs were invisible precisely because no equivalent of this was ever
/// produced for them.
public struct SyncOutcome: Sendable, Equatable {
    public var created: Int
    public var updated: Int
    public var deleted: Int
    public var unchanged: Int
    /// Broken out from `deleted` because a large value here is either a legitimate one-time
    /// repair or a sign something upstream is producing duplicates — the two must never be
    /// mistaken for each other in a log, which a single "deleted" count would do.
    public var duplicatesRemoved: Int

    public init(created: Int, updated: Int, deleted: Int, unchanged: Int, duplicatesRemoved: Int) {
        self.created = created
        self.updated = updated
        self.deleted = deleted
        self.unchanged = unchanged
        self.duplicatesRemoved = duplicatesRemoved
    }
}
