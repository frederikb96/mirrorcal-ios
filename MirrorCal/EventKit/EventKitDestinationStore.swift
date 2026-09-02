import EventKit
import Foundation
import MirrorCalKit

/// `DestinationCalendarStore` bound to one CalDAV (or any EventKit) calendar. Symmetrically with
/// `EventKitSourceCalendar`, this is the file where the destination side of the safety boundary
/// actually lives: every write goes through `stage`/`commit`, never immediately, so a whole plan
/// reaches the calendar as one round trip — the EventKit report's estimate is a few thousand
/// writes on the first sync for a busy calendar.
///
/// `final class` rather than a struct: `commit()` mutates a pending-action buffer that has to
/// survive across the `stage` calls that built it, which a value type would silently copy.
/// `@unchecked Sendable` for the same reason `EventKitSourceCalendar` is — `EKEventStore` has no
/// `Sendable` conformance of its own, and every access here is confined to one caller's sequence
/// of `stage`/`commit` calls, never touched concurrently from two tasks at once.
public final class EventKitDestinationStore: DestinationCalendarStore, @unchecked Sendable {
    private let store: EKEventStore
    private let calendarIdentifier: String
    private var pendingActions: [DestinationWriteAction] = []

    public init(store: EKEventStore, calendar: EKCalendar) {
        self.store = store
        self.calendarIdentifier = calendar.calendarIdentifier
    }

    /// Everything in the window, stamped and unstamped alike — `SyncEngine.plan` is what filters
    /// to stamped events, and `DestinationGuard` needs to see the unstamped ones to refuse a
    /// misconfigured calendar before anything is ever written to it.
    public func events(in window: DateInterval) throws -> [DestinationEvent] {
        guard let calendar = resolvedCalendar() else {
            throw EventKitCalendarError.calendarNotFound
        }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar])
        var results: [DestinationEvent] = []
        store.enumerateEvents(matching: predicate) { event, _ in
            results.append(Self.map(event))
        }
        return results
    }

    public func stage(_ action: DestinationWriteAction) throws {
        pendingActions.append(action)
    }

    /// Applies every staged action against the real store, then commits once. A staged update or
    /// delete whose target `EKEventStore.calendarItem(withIdentifier:)` can no longer find is
    /// skipped rather than thrown — Apple documents that a full calendar sync can invalidate a
    /// destination identifier, and the next ordinary sync's own fresh `events(in:)` scan will see
    /// whatever the real state actually is and reconcile from there, which is the same
    /// self-healing property `SyncEngine.plan` already has for every other kind of drift.
    public func commit() throws {
        guard let calendar = resolvedCalendar() else {
            throw EventKitCalendarError.calendarNotFound
        }
        for action in pendingActions {
            switch action {
            case .create(let content):
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                apply(content, to: event)
                try store.save(event, span: .thisEvent, commit: false)
            case .update(let identifier, let content):
                guard let event = store.calendarItem(withIdentifier: identifier) as? EKEvent else { continue }
                apply(content, to: event)
                try store.save(event, span: .thisEvent, commit: false)
            case .delete(let identifier):
                guard let event = store.calendarItem(withIdentifier: identifier) as? EKEvent else { continue }
                try store.remove(event, span: .thisEvent, commit: false)
            }
        }
        pendingActions = []
        try store.commit()
    }

    private func resolvedCalendar() -> EKCalendar? {
        store.calendar(withIdentifier: calendarIdentifier)
    }

    /// The only place `MirrorContent` is written into an `EKEvent`. Deliberately does not touch
    /// `event.alarms`: `MirrorContent` carries no alarm data at all (the source's own alarms are
    /// never copied — a mirrored event that buzzes is a bug), so a fresh `EKEvent` simply starts
    /// with none, and an *update* leaves whatever is already there untouched rather than wiping a
    /// reminder Freddy may have added to the mirrored event by hand.
    private func apply(_ content: MirrorContent, to event: EKEvent) {
        event.title = content.title
        event.location = content.location
        event.notes = content.notes
        event.startDate = content.occurrenceStart
        event.endDate = content.occurrenceEnd
        event.isAllDay = content.isAllDay
        event.availability = Self.ekAvailability(for: content.availability)
        event.timeZone = content.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        event.url = EventKitStamp.url(for: content.stamp)
    }

    private static func map(_ event: EKEvent) -> DestinationEvent {
        DestinationEvent(
            identifier: event.calendarItemIdentifier,
            stamp: EventKitStamp.stamp(from: event.url),
            title: event.title ?? "",
            location: event.location,
            notes: event.notes,
            occurrenceStart: event.startDate,
            occurrenceEnd: event.endDate,
            isAllDay: event.isAllDay,
            availability: mirrorAvailability(for: event.availability),
            timeZoneIdentifier: event.isAllDay ? nil : event.timeZone?.identifier
        )
    }

    private static func ekAvailability(for value: EventAvailability) -> EKEventAvailability {
        switch value {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        }
    }

    private static func mirrorAvailability(for value: EKEventAvailability) -> EventAvailability {
        switch value {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        case .notSupported: .busy
        @unknown default: .busy
        }
    }
}
