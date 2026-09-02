import EventKit
import Foundation
import MirrorCalKit

public enum EventKitCalendarError: Error, Sendable, Equatable {
    case calendarNotFound
}

/// `SourceCalendarReading` bound to one Exchange (or any EventKit) calendar. This file is the
/// half of the safety constraint that has to actually hold, not merely be expressed by a
/// protocol: nothing here calls `store.save`, `store.remove`, or anything else that writes —
/// there is no such call in this type, and `SourceCalendarReading` exposes no method that could
/// reach one even by mistake.
///
/// `@unchecked Sendable`: `EKEventStore` predates Swift concurrency and carries no `Sendable`
/// conformance of its own, but every access here is synchronous and confined to whichever
/// `Task` calls `events(in:)` — the same reasoning `DebugBridge` already uses for `NWListener`.
public struct EventKitSourceCalendar: SourceCalendarReading, @unchecked Sendable {
    private let store: EKEventStore
    private let calendarIdentifier: String

    public init(store: EKEventStore, calendar: EKCalendar) {
        self.store = store
        self.calendarIdentifier = calendar.calendarIdentifier
    }

    /// Cancelled occurrences are included, not filtered — `SyncEngine.plan` is documented as the
    /// place that happens, so a reader that filtered too would be a second implementation of the
    /// same decision with no way to notice the two disagree.
    public func events(in window: DateInterval) throws -> [SourceEventInstance] {
        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
            throw EventKitCalendarError.calendarNotFound
        }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar])
        var instances: [SourceEventInstance] = []
        store.enumerateEvents(matching: predicate) { event, _ in
            if let instance = Self.map(event) { instances.append(instance) }
        }
        return instances
    }

    /// Expansion, not the recurrence rule — `enumerateEvents` already hands back one `EKEvent`
    /// per occurrence with detachment and cancellation already resolved, which is the entire
    /// reason the EventKit report recommends never touching `EKRecurrenceRule` directly.
    ///
    /// `nil` when an event carries neither identifier at all — both are optional in EventKit, and
    /// a fallback identifier generated fresh on every scan would be a new mirror identity each
    /// run, which is worse than skipping the occurrence for the one sync where it happens.
    private static func map(_ event: EKEvent) -> SourceEventInstance? {
        guard let externalIdentifier = event.calendarItemExternalIdentifier ?? event.eventIdentifier else {
            return nil
        }
        return SourceEventInstance(
            externalIdentifier: externalIdentifier,
            occurrenceStart: event.startDate,
            occurrenceEnd: event.endDate,
            isAllDay: event.isAllDay,
            title: event.title ?? "",
            location: event.location,
            notes: event.notes,
            availability: mirrorAvailability(for: event.availability),
            // `nil` for a floating event, per `EKEvent.occurrenceDate`'s own documented
            // behaviour for all-day events — copying the source's own zone rather than
            // synthesising one from the reading device is Android's D8 defect, not repeated here.
            timeZoneIdentifier: event.isAllDay ? nil : event.timeZone?.identifier,
            status: event.status == .canceled ? .cancelled : .confirmed
        )
    }

    /// `.notSupported` has no `EventAvailability` equivalent — degrading it to `.busy` rather
    /// than dropping the event is the same reasoning `EventAvailability.degraded` already uses
    /// for a destination that cannot express a finer distinction: block the hour, lose the label.
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
