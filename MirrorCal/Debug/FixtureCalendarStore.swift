#if DEBUG

    import Foundation
    import MirrorCalKit

    /// Seeds a simulator run with `EventFixtures.all` when the app launches with
    /// `--mirrorcal-fixtures` — no real calendar account exists on a fresh CI simulator, so this
    /// is what lets `Mac`'s screenshot step show populated, realistic screens anyway.
    ///
    /// A second, app-target-local pair rather than reusing `MirrorCalKitTests`' own
    /// `FakeSourceCalendar`/`FakeDestinationStore`: those live in the Tests module and are not
    /// part of the package's public API, so nothing outside `@testable import` can see them.
    /// `EventFixtures` itself is `public` and `#if DEBUG` specifically so both sides can share the
    /// data even though neither can share the fake store type built on top of it.
    enum FixtureCalendarStore {

        static let sourceCalendarID = "fixture-source"
        static let destinationCalendarID = "fixture-destination"

        static var calendarSummaries: [CalendarSummary] {
            [
                CalendarSummary(
                    id: sourceCalendarID, title: "Fixture Source", accountName: "Fixture Account",
                    accountType: "Exchange", allowsContentModifications: false,
                    supportedAvailabilities: EventAvailability.allCases.map(\.rawValue).sorted()),
                CalendarSummary(
                    id: destinationCalendarID, title: "Fixture Destination", accountName: "Fixture Account",
                    accountType: "CalDAV", allowsContentModifications: true,
                    supportedAvailabilities: EventAvailability.allCases.map(\.rawValue).sorted()),
            ]
        }

        static func makePair() -> (source: any SourceCalendarReading, destination: any DestinationCalendarStore) {
            let instances = EventFixtures.all.flatMap(\.source)
            return (FixtureSourceCalendar(instances: instances), FixtureDestinationStore())
        }
    }

    /// Returns whatever was fixed at construction, filtered to the requested window — the
    /// app-target twin of `MirrorCalKitTests`' `FakeSourceCalendar`.
    private struct FixtureSourceCalendar: SourceCalendarReading {
        let instances: [SourceEventInstance]

        func events(in window: DateInterval) throws -> [SourceEventInstance] {
            instances.filter { window.contains($0.occurrenceStart) }
        }
    }

    /// An in-memory destination — `stage` only records intent, `commit` is where it takes effect,
    /// matching the real store's contract closely enough that fixture-mode screenshots show a
    /// calendar that actually converges rather than one that always looks freshly empty.
    private final class FixtureDestinationStore: DestinationCalendarStore, @unchecked Sendable {
        private var storedEvents: [String: DestinationEvent] = [:]
        private var pendingActions: [DestinationWriteAction] = []
        private var nextIdentifier = 1

        func events(in window: DateInterval) throws -> [DestinationEvent] {
            storedEvents.values.filter { window.contains($0.occurrenceStart) }
        }

        func stage(_ action: DestinationWriteAction) throws {
            pendingActions.append(action)
        }

        func commit() throws {
            for action in pendingActions {
                switch action {
                case .create(let content):
                    let identifier = "fixture-\(nextIdentifier)"
                    nextIdentifier += 1
                    storedEvents[identifier] = event(identifier: identifier, content: content)
                case .update(let identifier, let content):
                    storedEvents[identifier] = event(identifier: identifier, content: content)
                case .delete(let identifier):
                    storedEvents.removeValue(forKey: identifier)
                }
            }
            pendingActions = []
        }

        private func event(identifier: String, content: MirrorContent) -> DestinationEvent {
            DestinationEvent(
                identifier: identifier,
                stamp: content.stamp,
                title: content.title,
                location: content.location,
                notes: content.notes,
                occurrenceStart: content.occurrenceStart,
                occurrenceEnd: content.occurrenceEnd,
                isAllDay: content.isAllDay,
                availability: content.availability,
                timeZoneIdentifier: content.timeZoneIdentifier
            )
        }
    }

#endif
