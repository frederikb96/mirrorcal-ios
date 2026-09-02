import Foundation

/// One occurrence of a source-calendar event, already expanded — the unit of work the sync
/// engine operates on. A recurring series is never represented as a series here; the calendar
/// access layer expands it into one `SourceEventInstance` per occurrence before the engine ever
/// sees it, the same shape `EKEventStore.enumerateEvents(matching:)` already produces and the
/// shape Android's `CalendarContract.Instances` produced before it.
///
/// Carries nothing this app does not read from the source: no attendees (EventKit exposes them
/// read-only with no setter, so copying was never an option), no organiser, no alarms.
public struct SourceEventInstance: Sendable, Equatable {
    /// `calendarItemExternalIdentifier` on the source event. Apple documents this as identical
    /// for every occurrence of a recurring event, which is exactly why `occurrenceStart` has to
    /// carry the rest of the identity — see `MirrorStamp`.
    public let externalIdentifier: String
    public let occurrenceStart: Date
    public let occurrenceEnd: Date
    public let isAllDay: Bool
    public let title: String
    public let location: String?
    public let notes: String?
    public let availability: EventAvailability
    /// The source event's own time zone, read from EventKit rather than synthesised from the
    /// writing device's current zone — Android's actual defect (D8 in the behavioural report).
    /// `nil` for a floating event (Apple's own description of an all-day event's `occurrenceDate`).
    public let timeZoneIdentifier: String?
    public let status: EventStatus

    public init(
        externalIdentifier: String,
        occurrenceStart: Date,
        occurrenceEnd: Date,
        isAllDay: Bool = false,
        title: String,
        location: String? = nil,
        notes: String? = nil,
        availability: EventAvailability = .busy,
        timeZoneIdentifier: String? = nil,
        status: EventStatus = .confirmed
    ) {
        self.externalIdentifier = externalIdentifier
        self.occurrenceStart = occurrenceStart
        self.occurrenceEnd = occurrenceEnd
        self.isAllDay = isAllDay
        self.title = title
        self.location = location
        self.notes = notes
        self.availability = availability
        self.timeZoneIdentifier = timeZoneIdentifier
        self.status = status
    }
}
