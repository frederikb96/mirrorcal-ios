import Foundation

@testable import MirrorCalKit

/// Returns whatever was fixed at construction, filtered to the requested window — a source
/// calendar the engine can be handed with no EventKit anywhere nearby.
struct FakeSourceCalendar: SourceCalendarReading {
    let instances: [SourceEventInstance]

    func events(in window: DateInterval) throws -> [SourceEventInstance] {
        instances.filter { window.contains($0.occurrenceStart) }
    }
}

/// An in-memory destination calendar. `stage` only records intent; `commit` is where it actually
/// takes effect — the same "stage then commit once" contract the real store has, close enough
/// that a test asserting mid-plan (before `commit`) catches the same mistake a real EventKit-
/// backed store would.
final class FakeDestinationStore: DestinationCalendarStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String: DestinationEvent] = [:]
    private var pendingActions: [DestinationWriteAction] = []
    private var nextIdentifier = 1
    private(set) var commitCount = 0

    init(seed: [DestinationEvent] = []) {
        for event in seed { storedEvents[event.identifier] = event }
    }

    func events(in window: DateInterval) throws -> [DestinationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents.values.filter { window.contains($0.occurrenceStart) }
    }

    func stage(_ action: DestinationWriteAction) throws {
        lock.lock()
        defer { lock.unlock() }
        pendingActions.append(action)
    }

    func commit() throws {
        lock.lock()
        defer { lock.unlock() }
        for action in pendingActions {
            switch action {
            case .create(let content):
                let identifier = "fake-\(nextIdentifier)"
                nextIdentifier += 1
                storedEvents[identifier] = event(identifier: identifier, content: content)
            case .update(let identifier, let content):
                storedEvents[identifier] = event(identifier: identifier, content: content)
            case .delete(let identifier):
                storedEvents.removeValue(forKey: identifier)
            }
        }
        pendingActions = []
        commitCount += 1
    }

    /// Every event currently stored, window ignored — for asserting on final state without
    /// needing to guess a window wide enough to contain everything a test seeded or created.
    func allEvents() -> [DestinationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storedEvents.values)
    }

    /// Round-trips the stamp through `encoded`/`decode` exactly as a real CalDAV store would —
    /// storing `content.stamp` directly would skip the one boundary a written-then-read-back
    /// stamp actually has to survive, which is precisely how a stamp that decodes to something
    /// different than it encoded (an empty external identifier, for instance) could pass 57 green
    /// tests while being broken in real use.
    private func event(identifier: String, content: MirrorContent) -> DestinationEvent {
        DestinationEvent(
            identifier: identifier,
            stamp: MirrorStamp.decode(content.stamp.encoded),
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
