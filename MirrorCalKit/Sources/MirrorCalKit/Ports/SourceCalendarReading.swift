import Foundation

/// The read half of the calendar boundary. Every conforming type is bound to one source calendar
/// at construction — the protocol itself takes no calendar argument — and exposes reading only.
///
/// This is what makes writing to the source structurally impossible rather than merely avoided:
/// there is no method here an engine holding only a `SourceCalendarReading` could call to insert,
/// update, or delete anything. The app target's EventKit implementation of this protocol is where
/// that guarantee has to actually hold, but the guarantee is expressed here, in the shape every
/// implementation is forced to have.
public protocol SourceCalendarReading: Sendable {
    /// Every occurrence in `window`, already expanded — cancelled occurrences included, since
    /// filtering them is `SyncEngine.plan`'s job, not the reader's. A fake used in tests can
    /// return a fixed array; the EventKit implementation calls `enumerateEvents(matching:)`.
    func events(in window: DateInterval) throws -> [SourceEventInstance]
}
