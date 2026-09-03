import XCTest

@testable import MirrorCalKit

/// `EventKitStamp`'s own doc comment calls the CalDAV round trip of `url` unverified without a
/// device. If it does not survive, every previously-mirrored event loses its stamp on the next
/// read and gets recreated — linear growth, +N per sync, with nothing in the engine to bound it
/// (the terminal review measured this: five figures within a day). These tests model exactly that
/// shape — a destination already holding roughly as many of this installation's own events as the
/// plan is about to create — and confirm `apply` refuses to write anything rather than repeating
/// the corpus.
final class CircuitBreakerTests: XCTestCase {

    private let engine = SyncEngine()

    private func sourceCorpus(count: Int) -> [SourceEventInstance] {
        (0..<count).map { index in
            SourceEventInstance(
                externalIdentifier: "src-\(index)",
                occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 3600),
                occurrenceEnd: Date(timeIntervalSince1970: 1_780_001_800 + Double(index) * 3600),
                title: "Meeting \(index)"
            )
        }
    }

    /// Destination events stamped by this installation, but keyed to a *different* set of source
    /// identifiers than `sourceCorpus` — modelling the destination's own stamp having survived as
    /// a string (so it still counts as "owned"), while the key it decodes to no longer matches
    /// anything the current source produces. This is deliberately not the only way the real bug
    /// could look; it is the shape the breaker is built to catch regardless of which failure
    /// produced it.
    private func unmatchedOwnedDestination(count: Int) -> [DestinationEvent] {
        (0..<count).map { index in
            DestinationEvent(
                identifier: "dest-\(index)",
                stamp: MirrorStamp(
                    sourceExternalIdentifier: "old-\(index)",
                    occurrenceStart: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600)),
                title: "Meeting \(index)",
                occurrenceStart: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600),
                occurrenceEnd: Date(timeIntervalSince1970: 1_700_001_800 + Double(index) * 3600)
            )
        }
    }

    /// Watched failing before the breaker existed: with no guard at all, this scenario is exactly
    /// `apply`'s ordinary behaviour — it stages 40 creations and commits them, doubling the
    /// destination on the spot. That is the bug; this test is what makes it a compile-time-checked
    /// regression rather than a probe that gets deleted after proving the point once.
    func testApplyRefusesAPlanThatWouldRepeatTheExistingCorpus() async throws {
        let destination = unmatchedOwnedDestination(count: 40)
        let plan = engine.plan(
            source: sourceCorpus(count: 40), destination: destination, configuration: SyncConfiguration())
        XCTAssertEqual(plan.creations.count, 40, "sanity: none of the 40 should match by key")
        XCTAssertEqual(plan.existingOwnedByInstall, 40)

        let store = FakeDestinationStore(seed: destination)
        XCTAssertThrowsError(try engine.apply(plan, to: store)) { error in
            guard case SyncApplyError.suspectedRunaway(let creations, let existingOwned) = error else {
                return XCTFail("expected .suspectedRunaway, got \(error)")
            }
            XCTAssertEqual(creations, 40)
            XCTAssertEqual(existingOwned, 40)
        }
        XCTAssertEqual(store.commitCount, 0, "a refused plan must write nothing at all, not a partial batch")
        XCTAssertEqual(store.allEvents().count, 40, "the destination must be untouched")
    }

    /// The case that must always work regardless of threshold tuning: nothing has been mirrored
    /// here yet, so there is nothing for a large creation batch to be a repeat of.
    func testFirstSyncIntoAnEmptyCalendarIsNeverRefused() async throws {
        let plan = engine.plan(source: sourceCorpus(count: 200), destination: [], configuration: SyncConfiguration())
        XCTAssertEqual(plan.existingOwnedByInstall, 0)

        let store = FakeDestinationStore()
        XCTAssertNoThrow(try engine.apply(plan, to: store))
        XCTAssertEqual(store.allEvents().count, 200)
    }

    /// An ordinary bulk change on an established mirror — most of the corpus already matches, only
    /// a handful of new events are being added — must not be mistaken for a runaway.
    func testOrdinaryBulkAdditionOnAnEstablishedMirrorIsNotRefused() async throws {
        let existingCount = 100
        let existingSource = sourceCorpus(count: existingCount)
        let seedPlan = engine.plan(source: existingSource, destination: [], configuration: SyncConfiguration())
        let store = FakeDestinationStore()
        _ = try engine.apply(seedPlan, to: store)
        XCTAssertEqual(store.allEvents().count, existingCount)

        // Ten genuinely new events alongside the hundred that already match.
        let grown =
            existingSource
            + sourceCorpus(count: 10).map { instance in
                SourceEventInstance(
                    externalIdentifier: "new-\(instance.externalIdentifier)",
                    occurrenceStart: instance.occurrenceStart.addingTimeInterval(10 * 365 * 24 * 3600),
                    occurrenceEnd: instance.occurrenceEnd.addingTimeInterval(10 * 365 * 24 * 3600),
                    title: instance.title
                )
            }
        let plan = engine.plan(
            source: grown, destination: try store.events(in: wideWindow), configuration: SyncConfiguration())
        XCTAssertEqual(plan.creations.count, 10)
        XCTAssertEqual(plan.existingOwnedByInstall, existingCount)

        XCTAssertNoThrow(try engine.apply(plan, to: store))
        XCTAssertEqual(store.allEvents().count, existingCount + 10)
    }

    /// The conscious escape hatch: `force: true` writes the plan regardless of the breaker,
    /// because nothing here may set it silently on the caller's behalf.
    func testForceBypassesTheBreakerAndWritesThePlan() async throws {
        let destination = unmatchedOwnedDestination(count: 40)
        let plan = engine.plan(
            source: sourceCorpus(count: 40), destination: destination, configuration: SyncConfiguration())
        let store = FakeDestinationStore(seed: destination)

        XCTAssertNoThrow(try engine.apply(plan, to: store, force: true))
        XCTAssertEqual(store.commitCount, 1)
    }

    private var wideWindow: DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 4_000_000_000))
    }
}
