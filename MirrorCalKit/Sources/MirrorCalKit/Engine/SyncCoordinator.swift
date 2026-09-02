/// Serializes sync runs without ever silently dropping one — the fix for Android's `tryLock`,
/// which returned an empty, error-free success the moment a second sync arrived while one was
/// already running. That result was indistinguishable from "nothing needed to change," so a
/// calendar change that arrived mid-run was invisible until something else happened to trigger a
/// later sync — the strongest code-grounded explanation the Android investigation found for
/// events sometimes not showing up at all.
///
/// A request arriving mid-run is coalesced into exactly one further run that starts after the
/// current one finishes, and every request that coalesced this way is resolved with *that* run's
/// outcome, never the one already in flight when it asked — asking for a sync has to mean "give
/// me a result computed after this moment," or a coalesced caller could be told about a state
/// that predates its own request. The caller who asked first, by contrast, gets its own run's
/// outcome the moment that run finishes — it does not wait around for whatever coalesces after it.
public actor SyncCoordinator {
    public enum Trigger: Sendable, Equatable {
        case foreground, shortcut, push, backgroundRefresh, backgroundProcessing, manual
        /// A run started only because requests coalesced into it — never requested directly.
        case coalesced
    }

    public enum Event: Sendable, Equatable {
        case started(Trigger)
        case coalesced(Trigger)
        case finished(Trigger, SyncOutcome)
        case failed(Trigger, String)
    }

    private var isRunning = false
    private var waiters: [CheckedContinuation<SyncOutcome, Error>] = []

    private let perform: @Sendable (Trigger) async throws -> SyncOutcome
    private let record: @Sendable (Event) -> Void

    public init(
        perform: @escaping @Sendable (Trigger) async throws -> SyncOutcome,
        record: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.perform = perform
        self.record = record
    }

    /// Visible at `internal` access for tests only, via `@testable import` — lets a test wait for
    /// "the second request has actually coalesced" as a real condition instead of guessing at a
    /// delay.
    var waitingCount: Int { waiters.count }

    @discardableResult
    public func requestSync(trigger: Trigger) async throws -> SyncOutcome {
        if isRunning {
            record(.coalesced(trigger))
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        isRunning = true
        do {
            let outcome = try await runOnce(trigger: trigger)
            // Whoever arrived while this ran gets served by further rounds below — but this
            // caller already has its own answer and must not be made to wait for theirs too.
            Task { await self.drainWaiters() }
            return outcome
        } catch {
            Task { await self.drainWaiters() }
            throw error
        }
    }

    /// The one place `perform` is actually called, for a direct request or a coalesced round
    /// alike — logging is identical either way, which is what "every run is visible in the log"
    /// means in practice.
    private func runOnce(trigger: Trigger) async throws -> SyncOutcome {
        record(.started(trigger))
        do {
            let outcome = try await perform(trigger)
            record(.finished(trigger, outcome))
            return outcome
        } catch {
            record(.failed(trigger, String(describing: error)))
            throw error
        }
    }

    /// Runs one further round for everyone currently waiting, resolves them all with that one
    /// round's result, and checks again — repeating until a round starts with nothing new having
    /// arrived, at which point the coordinator goes idle. A round's own failure does not stop the
    /// loop: it resolves that round's waiters with the failure and keeps checking for anyone who
    /// arrived since, rather than leaving them stranded on an unrelated error.
    private func drainWaiters() async {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }
        let pending = waiters
        waiters = []
        do {
            let outcome = try await runOnce(trigger: .coalesced)
            pending.forEach { $0.resume(returning: outcome) }
        } catch {
            pending.forEach { $0.resume(throwing: error) }
        }
        await drainWaiters()
    }
}
