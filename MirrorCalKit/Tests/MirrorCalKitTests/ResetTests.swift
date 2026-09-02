import XCTest

@testable import MirrorCalKit

final class ResetTests: XCTestCase {

    private func stamped(_ identifier: String, externalId: String = "ext-1") -> DestinationEvent {
        DestinationEvent(
            identifier: identifier,
            stamp: MirrorStamp(
                sourceExternalIdentifier: externalId, occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000)),
            title: "Team Sync",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600)
        )
    }

    private func unstamped(_ identifier: String) -> DestinationEvent {
        DestinationEvent(
            identifier: identifier,
            stamp: nil,
            title: "Anniversary dinner",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600)
        )
    }

    /// The verification criterion from row 43, in full: every stamped event is removed, the
    /// unstamped one is never even considered, and this must hold unconditionally — not merely
    /// for events the current source would still produce, which is the whole reason reset exists
    /// separately from an ordinary sync.
    func testResetRemovesEveryStampedEventAndNothingElse() async {
        let engine = SyncEngine()
        let destination = [
            stamped("a", externalId: "ext-1"), stamped("b", externalId: "ext-2-long-gone"), unstamped("c"),
        ]

        let deletions = engine.resetPlan(destination: destination)

        XCTAssertEqual(Set(deletions.map(\.destinationIdentifier)), ["a", "b"])
        XCTAssertTrue(deletions.allSatisfy { $0.reason == .reset })
    }

    func testResetOfAnAllUnstampedCalendarDeletesNothing() async {
        let engine = SyncEngine()
        XCTAssertTrue(engine.resetPlan(destination: [unstamped("a"), unstamped("b")]).isEmpty)
    }

    /// Applying a reset plan to a store, then syncing from scratch, must rebuild the mirror
    /// completely — reset is a rebuild trigger, not merely a deletion.
    func testAfterResetANormalSyncRebuildsFromScratch() async throws {
        let engine = SyncEngine()
        let store = FakeDestinationStore(seed: [stamped("a")])

        for deletion in engine.resetPlan(destination: store.allEvents()) {
            try store.stage(.delete(destinationIdentifier: deletion.destinationIdentifier))
        }
        try store.commit()
        XCTAssertTrue(store.allEvents().isEmpty)

        let instance = SourceEventInstance(
            externalIdentifier: "ext-1",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600),
            title: "Team Sync"
        )
        let plan = engine.plan(source: [instance], destination: store.allEvents(), configuration: SyncConfiguration())
        _ = try engine.apply(plan, to: store)

        XCTAssertEqual(store.allEvents().count, 1)
        XCTAssertEqual(store.allEvents().first?.title, "Team Sync")
    }
}
