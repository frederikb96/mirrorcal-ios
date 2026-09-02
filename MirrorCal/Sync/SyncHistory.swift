import Foundation
import MirrorCalKit

/// `SyncOutcome` itself carries no `Codable` conformance — it is a package type with no
/// persistence-format opinion, matching `FieldPolicy`'s own reasoning in `SyncSettings.swift`.
/// This is the one place that gap is closed, and it is reused by the debug bridge's `/sync` route
/// as well, rather than each having its own copy of the same five fields.
public struct SyncOutcomeRecord: Codable, Sendable, Equatable {
    public let created: Int
    public let updated: Int
    public let deleted: Int
    public let unchanged: Int
    public let duplicatesRemoved: Int

    public init(_ outcome: SyncOutcome) {
        created = outcome.created
        updated = outcome.updated
        deleted = outcome.deleted
        unchanged = outcome.unchanged
        duplicatesRemoved = outcome.duplicatesRemoved
    }
}

/// What the Status screen shows for "what the last sync did and when" — the human-readable
/// counterpart to `SyncCoordinator.Event`, which is typed for the coordinator's own coalescing
/// logic but not for display. Persisted so it survives a relaunch; nothing here is load-bearing
/// for correctness, only for the one thing a person with no debugger can otherwise never know.
public struct SyncHistoryEntry: Codable, Sendable, Equatable {
    public let at: Date
    /// The finer-grained trigger description — "foreground activation", "calendar changed
    /// (foreground)", "silent push", and so on. `SyncCoordinator.Trigger` stays coarse (it only
    /// needs to distinguish what it coalesces on); this is what actually answers "why did this
    /// run happen", in the words a person reads.
    public let reason: String
    public let outcome: SyncOutcomeRecord?
    public let errorDescription: String?

    public init(at: Date, reason: String, outcome: SyncOutcomeRecord?, errorDescription: String?) {
        self.at = at
        self.reason = reason
        self.outcome = outcome
        self.errorDescription = errorDescription
    }

    public var succeeded: Bool { errorDescription == nil }
}

public final class SyncHistoryStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "mirrorcal.sync-history.last"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadLast() -> SyncHistoryEntry? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SyncHistoryEntry.self, from: data)
    }

    public func recordSuccess(reason: String, outcome: SyncOutcome, at: Date = Date()) {
        save(SyncHistoryEntry(at: at, reason: reason, outcome: SyncOutcomeRecord(outcome), errorDescription: nil))
    }

    public func recordFailure(reason: String, error: String, at: Date = Date()) {
        save(SyncHistoryEntry(at: at, reason: reason, outcome: nil, errorDescription: error))
    }

    private func save(_ entry: SyncHistoryEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        defaults.set(data, forKey: key)
    }
}
