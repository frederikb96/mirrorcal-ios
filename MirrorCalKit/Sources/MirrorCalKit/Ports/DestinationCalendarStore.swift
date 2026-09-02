import Foundation

/// One write the engine has decided on. Never executed directly — always staged and applied as a
/// batch, so a whole plan reaches the destination as one `commit()` rather than one round trip
/// per event; the first sync on a busy calendar is a few thousand of these.
public enum DestinationWriteAction: Sendable, Equatable {
    case create(MirrorContent)
    case update(destinationIdentifier: String, content: MirrorContent)
    case delete(destinationIdentifier: String)
}

/// The write half of the calendar boundary. Bound to one destination calendar at construction,
/// symmetrically with `SourceCalendarReading` being bound to the source — there is deliberately
/// no single type that conforms to both, so an engine holding a reader and a store cannot be
/// handed the wrong pair by a caller who has both in scope.
///
/// `stage` never touches the calendar by itself; only `commit` does. Nothing here has a `delete`
/// entry point that takes an event outside this store's own calendar, and nothing here lets a
/// caller reach the source calendar at all.
public protocol DestinationCalendarStore: Sendable {
    /// Every event currently in the destination calendar's window — stamped and unstamped alike.
    /// `SyncEngine.plan` is what filters to stamped events; this returns everything so the
    /// destination-guard check (row 38) can see what an unstamped event even looks like.
    func events(in window: DateInterval) throws -> [DestinationEvent]

    func stage(_ action: DestinationWriteAction) throws
    func commit() throws
}
