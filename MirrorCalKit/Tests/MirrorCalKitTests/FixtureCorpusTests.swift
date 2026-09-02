import XCTest

@testable import MirrorCalKit

/// Round-trips every case in `EventFixtures` through `SyncEngine.plan` — the same corpus the app
/// target reuses to seed a simulator, exercised here for free on Linux instead of only ever being
/// looked at on a screen.
final class FixtureCorpusTests: XCTestCase {

    private let engine = SyncEngine()

    func testRecurringSeriesProducesOneCreationPerOccurrence() async {
        let plan = engine.plan(
            source: EventFixtures.recurringSeries.source, destination: [], configuration: SyncConfiguration())
        XCTAssertEqual(plan.creations.count, 4)
        XCTAssertEqual(Set(plan.creations.map(\.stamp.key)).count, 4, "every occurrence must get a distinct key")
    }

    /// The detached occurrence shares its series identifier with the unmodified occurrence next
    /// to it in the same fixture — this is what proves the stamp key is per-*occurrence*, not
    /// per-series, since both entries here would collapse into one if it were not.
    func testDetachedOccurrenceIsDistinctFromItsSeriesSibling() async {
        let plan = engine.plan(
            source: EventFixtures.detachedOccurrence.source, destination: [], configuration: SyncConfiguration())
        XCTAssertEqual(plan.creations.count, 2)
        XCTAssertEqual(Set(plan.creations.map(\.title)), ["Team Sync", "Team Sync (moved)"])
    }

    func testCancelledOccurrenceProducesNoPlanAtAll() async {
        let plan = engine.plan(
            source: EventFixtures.cancelledOccurrence.source, destination: [], configuration: SyncConfiguration())
        XCTAssertTrue(plan.isEmpty)
    }

    func testAllDayEventKeepsItsFlagAndCarriesNoTimeZone() async {
        let plan = engine.plan(
            source: EventFixtures.allDayEvent.source, destination: [], configuration: SyncConfiguration())
        guard let created = plan.creations.first else { return XCTFail("expected one creation") }
        XCTAssertTrue(created.isAllDay)
        XCTAssertNil(created.timeZoneIdentifier)
    }

    /// Instances are absolute `Date` values, already resolved by whatever produced them — the
    /// engine does no time-zone arithmetic of its own, so a two-hour span either side of a DST
    /// transition must still measure as exactly two hours after round-tripping through a plan.
    func testEventSpanningADSTTransitionKeepsItsAbsoluteDuration() async throws {
        let plan = engine.plan(
            source: EventFixtures.dstBoundaryEvent.source, destination: [], configuration: SyncConfiguration())
        let created = try XCTUnwrap(plan.creations.first)
        XCTAssertEqual(created.occurrenceEnd.timeIntervalSince(created.occurrenceStart), 7200)
    }

    func testCrossTimeZoneEventCarriesTheSourcesOwnTimeZone() async throws {
        let plan = engine.plan(
            source: EventFixtures.crossTimeZoneEvent.source, destination: [], configuration: SyncConfiguration())
        let created = try XCTUnwrap(plan.creations.first)
        XCTAssertEqual(created.timeZoneIdentifier, "Asia/Tokyo")
    }

    /// The default policy drops descriptions; this fixture is only a meaningful "long text"
    /// exercise once a configuration actually asks for it to be copied.
    func testLongDescriptionSurvivesUntruncatedWhenPolicySaysCopy() async throws {
        let configuration = SyncConfiguration(descriptionPolicy: .copy)
        let plan = engine.plan(
            source: EventFixtures.longDescriptionEvent.source, destination: [], configuration: configuration)
        let created = try XCTUnwrap(plan.creations.first)
        let expectedLength = String(repeating: "Agenda item. ", count: 200).count
        XCTAssertEqual(
            created.notes?.count, expectedLength, "no truncation should happen anywhere in the mirroring path")
    }

    func testExcludedTitleFixtureIsSkippedOnlyWhenConfiguredAsExcluded() async {
        let excluding = SyncConfiguration(excludedTitles: ["Focus time"])
        XCTAssertTrue(
            engine.plan(source: EventFixtures.excludedTitleEvent.source, destination: [], configuration: excluding)
                .isEmpty)

        let notExcluding = SyncConfiguration()
        XCTAssertEqual(
            engine.plan(source: EventFixtures.excludedTitleEvent.source, destination: [], configuration: notExcluding)
                .creations.count,
            1,
            "the fixture must be an ordinary mirrorable event when nothing excludes it — otherwise this test would pass for the wrong reason"
        )
    }

    /// The whole corpus, applied to a fresh store in one pass, must produce exactly one
    /// destination event per non-cancelled source instance with no collisions — the sanity check
    /// that the app target's simulator seeding will actually rely on.
    func testWholeCorpusAppliesWithoutIdentifierOrKeyCollisions() async throws {
        let allSource = EventFixtures.all.flatMap(\.source)
        let plan = engine.plan(
            source: allSource, destination: [], configuration: SyncConfiguration(descriptionPolicy: .copy))
        let store = FakeDestinationStore()
        _ = try engine.apply(plan, to: store)

        let nonCancelled = allSource.filter { $0.status != .cancelled }
        XCTAssertEqual(store.allEvents().count, nonCancelled.count)
        XCTAssertEqual(
            Set(store.allEvents().map(\.identifier)).count, store.allEvents().count,
            "no two created events may share an identifier")
    }
}
