import Foundation

/// One event as it is actually observed in the destination calendar right now — never a
/// remembered belief about what was written there. Every decision the sync engine makes about an
/// existing destination event is made from this, not from a cache, which is what makes drift
/// unrepresentable: there is nothing else the engine could disagree with.
public struct DestinationEvent: Sendable, Equatable {
    /// The destination calendar's own local identifier for this event. Never treated as stable
    /// identity by the engine — only used within a single sync run to target an update or a
    /// delete — because Apple documents that a full calendar sync can invalidate it. Identity
    /// across runs comes from `stamp` alone.
    public let identifier: String
    /// `nil` when this event carries no valid MirrorCal stamp — the common case for everything in
    /// the calendar the app did not write. `SyncEngine.plan` never touches such an event: it is
    /// not in `byKey` at all, so it can appear in no creation, update, or deletion decision.
    public let stamp: MirrorStamp?
    public let title: String
    public let location: String?
    public let notes: String?
    public let occurrenceStart: Date
    public let occurrenceEnd: Date
    public let isAllDay: Bool
    public let availability: EventAvailability
    public let timeZoneIdentifier: String?

    public init(
        identifier: String,
        stamp: MirrorStamp?,
        title: String,
        location: String? = nil,
        notes: String? = nil,
        occurrenceStart: Date,
        occurrenceEnd: Date,
        isAllDay: Bool = false,
        availability: EventAvailability = .busy,
        timeZoneIdentifier: String? = nil
    ) {
        self.identifier = identifier
        self.stamp = stamp
        self.title = title
        self.location = location
        self.notes = notes
        self.occurrenceStart = occurrenceStart
        self.occurrenceEnd = occurrenceEnd
        self.isAllDay = isAllDay
        self.availability = availability
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}
