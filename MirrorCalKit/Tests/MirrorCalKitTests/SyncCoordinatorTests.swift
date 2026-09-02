import XCTest

@testable import MirrorCalKit

/// Blocks whoever calls `enter()` until the test explicitly `release()`s it — the mechanism that
/// lets these tests put a run "in flight" on purpose, deterministically, with no fixed delay
/// standing in for a real synchronization point.
private actor CallGate {
    private(set) var callCount = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enter() async {
        callCount += 1
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor EventRecorder {
    private(set) var events: [SyncCoordinator.Event] = []
    func record(_ event: SyncCoordinator.Event) { events.append(event) }
}

/// A plain incrementing counter, actor-isolated so it is safe to bump from `perform` closures
/// that genuinely run one after another but must not be assumed thread-confined otherwise.
private actor CallCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

private func outcome() -> SyncOutcome {
    SyncOutcome(created: 0, updated: 0, deleted: 0, unchanged: 0, duplicatesRemoved: 0)
}

final class SyncCoordinatorTests: XCTestCase {

    func testASingleUncontendedRequestRunsExactlyOnce() async throws {
        let gate = CallGate()
        let coordinator = SyncCoordinator(perform: { _ in
            await gate.enter()
            return outcome()
        })

        let task = Task { try await coordinator.requestSync(trigger: .foreground) }
        while await gate.callCount == 0 { await Task.yield() }
        await gate.release()

        _ = try await task.value
        let finalCallCount = await gate.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    /// The fix for Android's `tryLock`: a request arriving while another is in flight must
    /// coalesce into exactly one further run — never dropped silently (`tryLock` returned an
    /// empty success), and never one run per arrival either.
    func testRequestArrivingMidRunCoalescesIntoExactlyOneFurtherRun() async throws {
        let gate = CallGate()
        let coordinator = SyncCoordinator(perform: { _ in
            await gate.enter()
            return outcome()
        })

        let firstTask = Task { try await coordinator.requestSync(trigger: .foreground) }
        while await gate.callCount == 0 { await Task.yield() }

        let secondTask = Task { try await coordinator.requestSync(trigger: .manual) }
        while await coordinator.waitingCount == 0 { await Task.yield() }

        await gate.release()
        while await gate.callCount < 2 { await Task.yield() }
        await gate.release()

        _ = try await firstTask.value
        _ = try await secondTask.value

        let finalCallCount = await gate.callCount
        XCTAssertEqual(
            finalCallCount, 2,
            "a request arriving mid-run must trigger exactly one further run — not zero (dropped) and not one per arrival"
        )
    }

    /// A coalesced caller waits for a run that starts *after* it asked, not the answer from the
    /// run already in progress when it asked — otherwise it could be told about a state that
    /// predates its own request.
    func testCoalescedCallerReceivesTheOutcomeOfTheRunThatStartedAfterItAsked() async throws {
        let gate = CallGate()
        let counter = CallCounter()
        let coordinator = SyncCoordinator(perform: { _ in
            await gate.enter()
            let thisCall = await counter.next()
            return SyncOutcome(created: thisCall, updated: 0, deleted: 0, unchanged: 0, duplicatesRemoved: 0)
        })

        let firstTask = Task { try await coordinator.requestSync(trigger: .foreground) }
        while await gate.callCount == 0 { await Task.yield() }

        let secondTask = Task { try await coordinator.requestSync(trigger: .manual) }
        while await coordinator.waitingCount == 0 { await Task.yield() }

        await gate.release()
        while await gate.callCount < 2 { await Task.yield() }
        await gate.release()

        let firstOutcome = try await firstTask.value
        let secondOutcome = try await secondTask.value

        XCTAssertEqual(firstOutcome.created, 1, "the caller who asked first must see the first run's own outcome")
        XCTAssertEqual(
            secondOutcome.created, 2, "the coalesced caller must see the second run's outcome, not the first")
    }

    /// Row 28's own requirement: "every run — including a coalesced or skipped one — must be
    /// visible in the log." A coalesced request that never shows up as its own `.started` /
    /// `.finished` pair would be exactly Android's invisible dropped sync, just moved one layer up.
    func testEveryRunIncludingACoalescedOneIsRecorded() async throws {
        let gate = CallGate()
        let recorder = EventRecorder()
        let coordinator = SyncCoordinator(
            perform: { _ in
                await gate.enter()
                return outcome()
            },
            record: { event in Task { await recorder.record(event) } }
        )

        let firstTask = Task { try await coordinator.requestSync(trigger: .foreground) }
        while await gate.callCount == 0 { await Task.yield() }

        let secondTask = Task { try await coordinator.requestSync(trigger: .manual) }
        while await coordinator.waitingCount == 0 { await Task.yield() }

        await gate.release()
        while await gate.callCount < 2 { await Task.yield() }
        await gate.release()

        _ = try await firstTask.value
        _ = try await secondTask.value

        // `record` hops through an unstructured `Task`, so give the recorder a moment to catch up
        // to the terminal event rather than reading it mid-flight.
        while await recorder.events.count < 4 { await Task.yield() }
        let events = await recorder.events

        XCTAssertTrue(events.contains(.started(.foreground)))
        XCTAssertTrue(events.contains(.coalesced(.manual)))
        XCTAssertTrue(
            events.contains(.started(.coalesced)), "the coalesced run must be logged starting, not just requested")
        XCTAssertTrue(
            events.contains { if case .finished(.coalesced, _) = $0 { return true } else { return false } },
            "the coalesced run must be logged finishing"
        )
    }
}
