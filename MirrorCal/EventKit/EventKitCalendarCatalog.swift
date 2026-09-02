import EventKit
import Foundation
import MirrorCalKit

/// One calendar as it is useful to show a person choosing it, or to hand to a debug route —
/// enough to tell two calendars with the same name apart (`accountName`) and enough to warn
/// before a destination pick that cannot work (`allowsContentModifications`).
public struct CalendarSummary: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let accountName: String
    public let accountType: String
    public let allowsContentModifications: Bool
    public let supportedAvailabilities: [String]

    public init(
        id: String, title: String, accountName: String, accountType: String,
        allowsContentModifications: Bool, supportedAvailabilities: [String]
    ) {
        self.id = id
        self.title = title
        self.accountName = accountName
        self.accountType = accountType
        self.allowsContentModifications = allowsContentModifications
        self.supportedAvailabilities = supportedAvailabilities
    }
}

/// Lists what EventKit can currently see, and turns a calendar's own capability flags into the
/// `SyncConfiguration` inputs the engine needs — read at the moment they are needed rather than
/// assumed, since a calendar's `supportedEventAvailabilities` is a fact about that specific
/// calendar, not something safe to guess once and reuse.
public enum EventKitCalendarCatalog {

    public static func calendars(store: EKEventStore) -> [CalendarSummary] {
        store.calendars(for: .event).map(summarize).sorted { $0.title < $1.title }
    }

    public static func summarize(_ calendar: EKCalendar) -> CalendarSummary {
        CalendarSummary(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            accountName: calendar.source?.title ?? "Unknown account",
            accountType: accountType(for: calendar),
            allowsContentModifications: calendar.allowsContentModifications,
            supportedAvailabilities: supportedAvailabilities(calendar).map(\.rawValue).sorted()
        )
    }

    /// `EKCalendarEventAvailabilityMask` is a bitmask with no `.allCases`-style enumeration, so
    /// this is the one place every bit is checked explicitly — everything downstream reads a
    /// plain `Set<EventAvailability>` instead.
    public static func supportedAvailabilities(_ calendar: EKCalendar) -> Set<EventAvailability> {
        let mask = calendar.supportedEventAvailabilities
        var result: Set<EventAvailability> = []
        if mask.contains(.busy) { result.insert(.busy) }
        if mask.contains(.free) { result.insert(.free) }
        if mask.contains(.tentative) { result.insert(.tentative) }
        if mask.contains(.unavailable) { result.insert(.unavailable) }
        // A calendar reporting no supported values at all (some local calendars do) still has to
        // accept *something* — `.degraded` treats an empty set as "nothing survives but busy",
        // which is the safe default rather than a crash or a silently dropped block.
        return result
    }

    private static func accountType(for calendar: EKCalendar) -> String {
        switch calendar.source?.sourceType {
        case .local: "Local"
        case .exchange: "Exchange"
        case .calDAV: "CalDAV"
        case .mobileMe: "iCloud"
        case .subscribed: "Subscribed"
        case .birthdays: "Birthdays"
        case .none: "Unknown"
        @unknown default: "Unknown"
        }
    }
}
