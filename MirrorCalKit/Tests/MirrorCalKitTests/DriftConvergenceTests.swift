import XCTest

@testable import MirrorCalKit

/// Row 42 is the sharpest requirement in the whole spec: drift must not be representable, because
/// the plan is a function of what is observed on both sides right now, plus configuration —
/// nothing else. `SyncEngine.plan`'s signature already makes a cache impossible to pass in; these
/// tests exercise that guarantee one level up, at `SyncEngine.synchronize`, which does accept a
/// cache (so a caller has somewhere to persist one between launches) and is what a mutation to
/// "trust the cache" would actually have to alter.
final class DriftConvergenceTests: XCTestCase {

    private let engine = SyncEngine()
    private let window = DateInterval(
        start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 4_000_000_000))

    private func stamp(_ id: String, _ start: TimeInterval = 1_780_000_000) -> MirrorStamp {
        MirrorStamp(sourceExternalIdentifier: id, occurrenceStart: Date(timeIntervalSince1970: start))
    }

    /// One source calendar and one starting destination state, seeded with one of every branch
    /// `plan` can take: an already-correct mirror, a missing one, a drifted one, and an orphaned
    /// deletion candidate. Rebuilt fresh for each cache condition so no run can affect another.
    private func scenario() -> (source: [SourceEventInstance], seed: [DestinationEvent]) {
        let source = [
            SourceEventInstance(
                externalIdentifier: "unchanged-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
                occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800), title: "Already correct",
                timeZoneIdentifier: "Europe/Berlin"
            ),
            SourceEventInstance(
                externalIdentifier: "missing-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_100_000),
                occurrenceEnd: Date(timeIntervalSince1970: 1_780_101_800), title: "Needs creating",
                timeZoneIdentifier: "Europe/Berlin"
            ),
            SourceEventInstance(
                externalIdentifier: "drift-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_200_000),
                occurrenceEnd: Date(timeIntervalSince1970: 1_780_201_800), title: "Correct title now",
                timeZoneIdentifier: "Europe/Berlin"
            ),
        ]
        let seed = [
            DestinationEvent(
                identifier: "dest-unchanged", stamp: stamp("unchanged-1", 1_780_000_000), title: "Already correct",
                occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
                occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800),
                timeZoneIdentifier: "Europe/Berlin"
            ),
            DestinationEvent(
                identifier: "dest-drift", stamp: stamp("drift-1", 1_780_200_000), title: "Stale title",
                occurrenceStart: Date(timeIntervalSince1970: 1_780_200_000),
                occurrenceEnd: Date(timeIntervalSince1970: 1_780_201_800),
                timeZoneIdentifier: "Europe/Berlin"
            ),
            DestinationEvent(
                identifier: "dest-gone", stamp: stamp("gone-1", 1_780_300_000), title: "Source no longer has this",
                occurrenceStart: Date(timeIntervalSince1970: 1_780_300_000),
                occurrenceEnd: Date(timeIntervalSince1970: 1_780_301_800),
                timeZoneIdentifier: "Europe/Berlin"
            ),
        ]
        return (source, seed)
    }

    private func run(cache: SyncCache) throws -> [DestinationEvent] {
        let (source, seed) = scenario()
        let store = FakeDestinationStore(seed: seed)
        _ = try engine.synchronize(
            source: FakeSourceCalendar(instances: source),
            destination: store,
            cache: cache,
            configuration: SyncConfiguration(),
            window: window
        )
        return store.allEvents().sorted { $0.identifier < $1.identifier }
    }

    /// The test row 42 asks for by name: four cache conditions, one scenario, identical final
    /// destination state. Watched failing against a deliberately-mistrusting `synchronize` before
    /// being trusted — see the report's Testing section.
    func testFinalDestinationStateIsIdenticalAcrossEveryCacheCondition() async throws {
        let empty = SyncCache.empty
        let stale = SyncCache(hashesByStampKey: ["unchanged-1_1780000000": "0000000000000000"])
        let corrupted = SyncCache.loading(schemaVersion: 999, hashesByStampKey: ["not": "even", "the": "right shape"])
        let disagreeing = SyncCache(hashesByStampKey: [
            "unchanged-1_1780000000": "ffffffffffffffff",
            "drift-1_1780200000": ContentHasher.hash(
                MirrorContent(
                    stamp: stamp("drift-1", 1_780_200_000), title: "A hash the cache believes but reality does not",
                    location: nil, notes: nil, occurrenceStart: Date(timeIntervalSince1970: 1_780_200_000),
                    occurrenceEnd: Date(timeIntervalSince1970: 1_780_201_800), isAllDay: false, availability: .busy,
                    timeZoneIdentifier: "Europe/Berlin"
                )
            ),
        ])

        let results = try [empty, stale, corrupted, disagreeing].map { try run(cache: $0) }
        for result in results.dropFirst() {
            XCTAssertEqual(result, results[0], "the final destination state must not depend on the cache passed in")
        }

        // Confirm the scenario actually exercised every branch — a convergence test whose
        // scenario never diverges under any cache would pass for the wrong reason.
        XCTAssertEqual(
            results[0].count, 3,
            "unchanged, missing (now created), and drift (now corrected) should remain; gone should not")
        XCTAssertFalse(results[0].contains { $0.title == "Source no longer has this" })
        XCTAssertTrue(results[0].contains { $0.title == "Correct title now" })
    }

    // MARK: - Reconciliation (row 29) — the same mechanism, three angles on it

    /// Deleting a mirrored event by hand causes it to be restored on the next sync, without the
    /// source having changed at all — because the next sync simply observes it is missing, the
    /// same way it would observe anything else missing.
    func testHandDeletedMirroredEventIsRestoredWithoutASourceChange() async {
        let instance = SourceEventInstance(
            externalIdentifier: "ext-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800), title: "Team Sync",
            timeZoneIdentifier: "Europe/Berlin"
        )
        // No destination events at all — as if the user deleted the mirror and nothing else
        // about the world changed.
        let plan = engine.plan(source: [instance], destination: [], configuration: SyncConfiguration())
        XCTAssertEqual(plan.creations.count, 1)
        XCTAssertEqual(plan.creations.first?.title, "Team Sync")
    }

    /// A stamped event the engine has never "seen before" — an orphan from an earlier install, in
    /// the Android sense — is matched normally by its stamp and left alone if its content already
    /// matches. Nothing about this needs a special case, because there is no tracking store for
    /// it to be missing from in the first place.
    func testOrphanedStampedEventMatchingCurrentSourceIsAdoptedWithNoWrite() async {
        let instance = SourceEventInstance(
            externalIdentifier: "ext-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800), title: "Team Sync",
            timeZoneIdentifier: "Europe/Berlin"
        )
        let orphan = DestinationEvent(
            identifier: "dest-orphan", stamp: stamp("ext-1"), title: "Team Sync",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let plan = engine.plan(source: [instance], destination: [orphan], configuration: SyncConfiguration())
        XCTAssertTrue(plan.isEmpty, "an orphan that already matches must not be duplicated or rewritten")
        XCTAssertEqual(plan.unchanged.count, 1)
    }

    /// Content that drifted on the *destination* side — a hand edit to a mirrored event's title,
    /// with the source untouched — is reverted on the next sync, the same as source-side drift.
    func testHandEditedMirroredEventContentIsRevertedOnNextSync() async {
        let instance = SourceEventInstance(
            externalIdentifier: "ext-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800), title: "Team Sync",
            timeZoneIdentifier: "Europe/Berlin"
        )
        let handEdited = DestinationEvent(
            identifier: "dest-1", stamp: stamp("ext-1"), title: "Team Sync (rescheduled by hand)",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let plan = engine.plan(source: [instance], destination: [handEdited], configuration: SyncConfiguration())
        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.updates.first?.content.title, "Team Sync")
    }

    // MARK: - A mirror aging out of the sync window must still be deletable (row: window stranding)

    /// Scanning both sides over the same, narrow window is exactly the shape that strands a
    /// mirror once the event it came from ages out of that window (continuously, at the trailing
    /// edge, or abruptly when the window is narrowed): the destination scan simply never sees it
    /// again, so it can never be the far side of a `sourceNoLongerPresent` deletion. Watched
    /// failing first, by passing no `destinationWindow` (letting it default to the narrow one) —
    /// see the mutation this file's own report describes.
    func testAMirrorThatAgedOutOfTheNarrowSourceWindowIsStillDeletedWhenTheDestinationIsScannedWider() async throws {
        // A narrow "current" window that no longer contains the aged-out event's own occurrence —
        // modelling both the trailing-edge and the window-just-narrowed case identically, since
        // from `synchronize`'s point of view they are the same input.
        let narrowWindow = DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_800_000_000))
        // Just before the narrow window's own start — outside it, but well inside any sane
        // padding, which is the case that actually happens in production (an event aging out a
        // few months, or a window narrowed by a few months) rather than an extreme one.
        let agedOutStart = narrowWindow.start.addingTimeInterval(-5_000_000)
        let agedOutMirror = DestinationEvent(
            identifier: "dest-aged-out",
            stamp: MirrorStamp(sourceExternalIdentifier: "aged-out-1", occurrenceStart: agedOutStart),
            title: "Long gone from the source window",
            occurrenceStart: agedOutStart,
            occurrenceEnd: agedOutStart.addingTimeInterval(3_600)
        )
        let widePadding: TimeInterval = 2 * 365 * 24 * 3600
        let widerDestinationWindow = DateInterval(
            start: narrowWindow.start.addingTimeInterval(-widePadding),
            end: narrowWindow.end.addingTimeInterval(widePadding))

        let store = FakeDestinationStore(seed: [agedOutMirror])
        let result = try engine.synchronize(
            source: FakeSourceCalendar(instances: []),
            destination: store,
            cache: .empty,
            configuration: SyncConfiguration(),
            window: narrowWindow,
            destinationWindow: widerDestinationWindow
        )

        XCTAssertEqual(result.outcome.deleted, 1, "the aged-out mirror must be reachable by the delete pass")
        XCTAssertTrue(store.allEvents().isEmpty)
    }

    /// The default (`destinationWindow: nil`) must keep scanning both sides over the same window
    /// — this is the property that makes the wider parameter opt-in rather than a silent change
    /// in behaviour for every existing caller.
    func testWithNoDestinationWindowGivenBothSidesAreScannedOverTheSameWindow() async throws {
        let agedOutMirror = DestinationEvent(
            identifier: "dest-aged-out",
            stamp: stamp("aged-out-1", 100_000),
            title: "Outside the window on both sides",
            occurrenceStart: Date(timeIntervalSince1970: 100_000),
            occurrenceEnd: Date(timeIntervalSince1970: 103_600)
        )
        let narrowWindow = DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_800_000_000))
        let store = FakeDestinationStore(seed: [agedOutMirror])

        let result = try engine.synchronize(
            source: FakeSourceCalendar(instances: []),
            destination: store,
            cache: .empty,
            configuration: SyncConfiguration(),
            window: narrowWindow
        )

        XCTAssertEqual(result.outcome.deleted, 0, "invisible to both scans, so it cannot be deleted or created")
        XCTAssertEqual(store.allEvents().count, 1, "left exactly as it was — stranded, not touched")
    }
}
