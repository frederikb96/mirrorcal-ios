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

    // MARK: - Source-side stamp-key collisions self-heal too

    /// Two distinct source occurrences that happen to produce the same `MirrorStamp.key` — a
    /// real, reachable state per Apple's own documentation that `calendarItemExternalIdentifier`
    /// is not guaranteed unique per occurrence — must not silently collapse via ordinary
    /// dictionary overwrite. Order-independence is the sharpest way to see it: a plain
    /// `result[key] = content` loop keeps whichever instance the loop visits *last*, so the
    /// "surviving" title flips depending purely on array order, which is exactly what a silent,
    /// unlogged collision looks like from the outside.
    func testSourceSideStampKeyCollisionResolvesTheSameWayRegardlessOfInputOrder() async {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let a = instance(id: "series-x", start: 1_780_000_000, title: "Event A")
        let b = SourceEventInstance(
            externalIdentifier: "series-x", occurrenceStart: start, occurrenceEnd: start.addingTimeInterval(3600),
            title: "Event B", timeZoneIdentifier: "Europe/Berlin")

        let forward = engine.plan(source: [a, b], destination: [], configuration: SyncConfiguration())
        let reversed = engine.plan(source: [b, a], destination: [], configuration: SyncConfiguration())

        XCTAssertEqual(forward.creations.count, 1, "a colliding pair mirrors exactly one survivor")
        XCTAssertEqual(
            forward.creations.first?.title, reversed.creations.first?.title,
            "the survivor must be chosen deterministically, independent of input order")
        XCTAssertEqual(forward.sourceCollisions, [.init(key: forward.creations[0].stamp.key, count: 2)])
    }

    // MARK: - Unstampable source events are refused, not silently mirrored

    /// Apple documents `calendarItemExternalIdentifier` as optional — an empty one is a real
    /// state, not just a constructed edge case. Minting a stamp for it anyway encodes fine and
    /// decodes back as `nil` (see `MirrorStampTests`), so `plan` would treat the very event it
    /// just created as an ordinary hand-created event it must never touch again — never
    /// recognised as already mirrored, and therefore recreated on every following sync, forever.
    /// `FakeDestinationStore` round-trips the stamp through the same encode/decode boundary a
    /// real CalDAV store would, which is what lets this test see the orphan the way production
    /// code would rather than the way a store that merely remembers what it was told would.
    func testSourceEventWithAnEmptyExternalIdentifierNeverProducesAnUnboundedlyGrowingOrphan() async throws {
        let store = FakeDestinationStore()
        let unstampable = instance(id: "")

        var lastPlan = SyncPlan()
        for _ in 0..<3 {
            lastPlan = engine.plan(
                source: [unstampable], destination: try store.events(in: window), configuration: SyncConfiguration())
            _ = try engine.apply(lastPlan, to: store)
        }

        XCTAssertEqual(store.allEvents().count, 0, "an event that cannot be stamped safely must never be mirrored")
        XCTAssertEqual(lastPlan.unstampableSourceEvents, 1)
    }

    // MARK: - Cross-installation destination guard (row 38, extended)

    /// The stamp records which source event it came from, but — before this fix — nothing about
    /// which installation wrote it. So a second, independent MirrorCal install pointed at a
    /// different source calendar sees every one of the first install's mirrored events as
    /// "source no longer present," because its own desired set can never contain a key built from
    /// a source it never reads: the two installs mutually delete each other's events. Two
    /// distinct `installationIdentifier`s is what makes the fix actually testable — the shared
    /// default alone cannot tell "another install's event" apart from "my own event whose source
    /// occurrence is genuinely gone," which is the one case a delete pass must still catch.
    func testASyncNeverDeletesAStampedEventWrittenByADifferentInstallation() async {
        let installAsEvent = DestinationEvent(
            identifier: "dest-a",
            stamp: MirrorStamp(
                sourceExternalIdentifier: "install-a-ext", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
                installationIdentifier: "install-a"),
            title: "Install A's meeting",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800)
        )
        // Install B's own source calendar never contains "install-a-ext" — a different Exchange
        // account entirely — yet both installs write into the same shared destination calendar.
        let installBsSource = [instance(id: "install-b-ext", start: 1_780_100_000)]
        let installBsConfiguration = SyncConfiguration(installationIdentifier: "install-b")

        let planForInstallB = engine.plan(
            source: installBsSource, destination: [installAsEvent], configuration: installBsConfiguration)

        XCTAssertTrue(
            planForInstallB.deletions.isEmpty,
            "a sync must never delete an event written by a different installation")
    }

    /// The complementary case: a genuinely orphaned event from *this* installation's own earlier
    /// runs — no longer produced by its current source — must still be deleted. Cross-install
    /// protection must not degrade into "nothing is ever deleted."
    func testASyncStillDeletesItsOwnOrphanedEventWhenTheInstallationIdentifierMatches() async {
        let ownOrphan = DestinationEvent(
            identifier: "dest-gone",
            stamp: MirrorStamp(
                sourceExternalIdentifier: "long-gone", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
                installationIdentifier: "install-b"),
            title: "No longer on the calendar",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800)
        )
        let plan = engine.plan(
            source: [], destination: [ownOrphan],
            configuration: SyncConfiguration(installationIdentifier: "install-b"))

        XCTAssertEqual(plan.deletions.count, 1)
        XCTAssertEqual(plan.deletions.first?.destinationIdentifier, "dest-gone")
    }
}
