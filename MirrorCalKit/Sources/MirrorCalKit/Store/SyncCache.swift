/// A performance cache and nothing more: `SyncEngine.plan` never accepts one as a parameter and
/// never reads one, by construction — see `SyncEngine.swift`. Losing this file, corrupting it, or
/// loading one from a stale schema costs one sync's worth of redundant hash recomputation and
/// nothing else, which is what makes it safe to persist as a throwaway `Codable` JSON file rather
/// than a database: the destination calendar is the only thing that has to be durable.
///
/// Holds no destination identifier, deliberately: Apple documents that a full calendar sync can
/// invalidate `calendarItemIdentifier`, and the engine never looks an event up by a remembered
/// identifier anyway — it always re-matches by reading the stamp back out of the destination
/// event. A cached identifier would be exactly the kind of remembered state row 42 rules out.
public struct SyncCache: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Keyed by `MirrorStamp.key`.
    public var hashesByStampKey: [String: String]

    public init(schemaVersion: Int = SyncCache.currentSchemaVersion, hashesByStampKey: [String: String] = [:]) {
        self.schemaVersion = schemaVersion
        self.hashesByStampKey = hashesByStampKey
    }

    public static let empty = SyncCache()

    /// A schema mismatch is treated as `.empty` rather than as a parse error to migrate around —
    /// a wrong-schema cache is only ever a lost optimization, never a correctness risk, so there
    /// is nothing here worth writing migration code for.
    public static func loading(schemaVersion: Int, hashesByStampKey: [String: String]) -> SyncCache {
        schemaVersion == currentSchemaVersion
            ? SyncCache(schemaVersion: schemaVersion, hashesByStampKey: hashesByStampKey) : .empty
    }
}
