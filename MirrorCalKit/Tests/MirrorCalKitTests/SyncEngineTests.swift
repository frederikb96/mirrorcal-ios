import XCTest

@testable import MirrorCalKit

final class SyncEngineTests: XCTestCase {

    private let engine = SyncEngine()
    private let window = DateInterval(
        start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 4_000_000_000))

    private func instance(
        id: String = "ext-1",
        start: TimeInterval = 1_780_000_000,
        title: String = "Team Sync",
        status: EventStatus = .confirmed
    ) -> SourceEventInstance {
        SourceEventInstance(
            externalIdentifier: id,
            occurrenceStart: Date(timeIntervalSince1970: start),
            occurrenceEnd: Date(timeIntervalSince1970: start + 1800),
            title: title,
            timeZoneIdentifier: "Europe/Berlin",
            status: status
        )
    }

    // MARK: - The four branches

    func testNewSourceEventBecomesACreation() async {
        let plan = engine.plan(source: [instance()], destination: [], configuration: SyncConfiguration())
        XCTAssertEqual(plan.creations.count, 1)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testUnchangedSourceEventProducesNoWrite() async {
        let content = MirrorContent(mirroring: instance(), configuration: SyncConfiguration())
        let destinationEvent = DestinationEvent(
            identifier: "dest-1",
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
        let plan = engine.plan(
            source: [instance()], destination: [destinationEvent], configuration: SyncConfiguration())
        XCTAssertTrue(plan.creations.isEmpty)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.unchanged.count, 1)
    }

    func testChangedSourceEventBecomesAnUpdateOfTheExistingDestinationIdentifier() async {
        let stale = DestinationEvent(
            identifier: "dest-1",
            stamp: MirrorStamp(
                sourceExternalIdentifier: "ext-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000)),
            title: "Old Title",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800)
        )
        let plan = engine.plan(
            source: [instance(title: "New Title")], destination: [stale], configuration: SyncConfiguration())
        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.updates.first?.destinationIdentifier, "dest-1")
        XCTAssertEqual(plan.updates.first?.content.title, "New Title")
        XCTAssertTrue(plan.creations.isEmpty)
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testSourceEventNoLongerPresentBecomesADeletion() async {
        let orphaned = DestinationEvent(
            identifier: "dest-1",
            stamp: MirrorStamp(
                sourceExternalIdentifier: "ext-gone", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000)),
            title: "Gone",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800)
        )
        let plan = engine.plan(source: [], destination: [orphaned], configuration: SyncConfiguration())
        XCTAssertEqual(plan.deletions.count, 1)
        XCTAssertEqual(plan.deletions.first?.destinationIdentifier, "dest-1")
        XCTAssertEqual(plan.deletions.first?.reason, .sourceNoLongerPresent)
    }

    // MARK: - Filtering, before a plan is even built

    func testCancelledOccurrenceIsNeverMirrored() async {
        let plan = engine.plan(
            source: [instance(status: .cancelled)], destination: [], configuration: SyncConfiguration())
        XCTAssertTrue(plan.isEmpty)
    }

    func testExcludedTitleIsNeverMirrored() async {
        let configuration = SyncConfiguration(excludedTitles: ["Focus time"])
        let plan = engine.plan(source: [instance(title: "Focus time")], destination: [], configuration: configuration)
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - Unstamped events are never in scope

    /// The guard from row 38, expressed at the level `plan` itself operates on: an event with no
    /// stamp cannot appear as a deletion, because it can never enter `stampedDestinationEvents`
    /// in the first place — there is no code path from "unstamped event in the destination" to
    /// any action in the plan.
    func testUnstampedDestinationEventIsNeverTouched() async {
        let unstamped = DestinationEvent(
            identifier: "hand-created",
            stamp: nil,
            title: "Dentist",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800)
        )
        let plan = engine.plan(source: [], destination: [unstamped], configuration: SyncConfiguration())
        XCTAssertTrue(
            plan.isEmpty, "an unstamped event must never be deleted, even when nothing in the source matches it")
    }

    // MARK: - Idempotence — row 28's own verification criterion

    /// Applying the same plan to a fake store and re-planning against its resulting state must
    /// produce zero writes the second time — the property that turns a duplicated trigger into a
    /// no-op instead of a correctness bug.
    func testRunningTwiceOverUnchangedInputProducesNoWritesOnTheSecondRun() async throws {
        let store = FakeDestinationStore()
        let firstPlan = engine.plan(
            source: [instance()], destination: try store.events(in: window), configuration: SyncConfiguration())
        _ = try engine.apply(firstPlan, to: store)
        XCTAssertEqual(firstPlan.creations.count, 1)

        let secondPlan = engine.plan(
            source: [instance()], destination: try store.events(in: window), configuration: SyncConfiguration())
        XCTAssertTrue(secondPlan.creations.isEmpty)
        XCTAssertTrue(secondPlan.updates.isEmpty)
        XCTAssertTrue(secondPlan.deletions.isEmpty)
        XCTAssertEqual(secondPlan.unchanged.count, 1)
    }

    // MARK: - Duplicate stamps self-heal

    /// Two destination events under one stamp is drift, not a valid state — the engine must
    /// collapse it to one survivor and delete the rest rather than matching the first one it
    /// happens to find and silently ignoring the second.
    func testDuplicateStampedEventsAreCollapsedToOneSurvivor() async {
        let stamp = MirrorStamp(
            sourceExternalIdentifier: "ext-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000))
        let duplicateA = DestinationEvent(
            identifier: "dest-a", stamp: stamp, title: "Team Sync",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let duplicateB = DestinationEvent(
            identifier: "dest-b", stamp: stamp, title: "Team Sync",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let plan = engine.plan(
            source: [instance()], destination: [duplicateA, duplicateB], configuration: SyncConfiguration())

        XCTAssertEqual(plan.deletions.count, 1, "exactly one of the two duplicates must be removed")
        XCTAssertEqual(plan.deletions.first?.reason, .duplicateStamp)
        XCTAssertTrue(plan.creations.isEmpty, "the surviving duplicate already matches — no creation should be issued")
    }
}
