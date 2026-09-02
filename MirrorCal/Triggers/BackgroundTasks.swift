import BackgroundTasks
import Foundation
import MirrorCalKit

/// Registers and resubmits the two background tasks iOS actually offers a mirror app:
/// `BGAppRefreshTask` as a frequent, short-budget safety net, and `BGProcessingTask` as an
/// overnight, charger-only full reconcile. Both identifiers must also appear in
/// `BGTaskSchedulerPermittedIdentifiers` (`Config/Info.plist`) — a mismatch there fails at
/// `register`, silently, with the task simply never running.
///
/// Registration has to happen before `application(_:didFinishLaunchingWithOptions:)` returns
/// (Apple's own documented requirement), which is why this is driven from
/// `MirrorCalAppDelegate` rather than from `MirrorCalApp.init()` — a SwiftUI `App`'s `init` runs
/// before the delegate's launch callback, but "before" is not the same guarantee as "in the same
/// callback Apple's docs name".
enum BackgroundTasks {
    static let refreshIdentifier = "com.frederikberg.mirrorcal.refresh"
    static let processingIdentifier = "com.frederikberg.mirrorcal.reconcile"

    /// Not chunked or resumable — a large first sync is instead run in the foreground, immediately
    /// when sync is first enabled (`AppSyncEngine.updateSettings`), so what a `BGAppRefreshTask`
    /// actually has to fit in its ~30 seconds afterward is an ordinary small diff, not the initial
    /// burst.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            handle(task, reason: "background refresh", trigger: .backgroundRefresh, resubmit: scheduleRefresh)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            handle(
                task, reason: "background processing (reconcile)", trigger: .backgroundProcessing,
                resubmit: scheduleProcessing)
        }
    }

    /// Called once at launch and again after every run of its own task — `BGTaskScheduler` only
    /// ever queues one request per identifier, so a task that does not resubmit itself simply
    /// never runs again.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 60 * 60)
        request.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(request)
    }

    /// `BGTask` is not `Sendable`, and both the unstructured `Task` below and `expirationHandler`
    /// can genuinely run concurrently with each other — the exact shape Swift 6 flags as a data
    /// race risk. `BackgroundTaskHandle` wraps it as `@unchecked Sendable`, with `CompletionGuard`
    /// as the actual runtime proof: only one of the two ever gets past `markCompleted()`, so only
    /// one of them ever touches `task` for real, whichever wins the race to finish first.
    private static func handle(
        _ task: BGTask, reason: String, trigger: SyncCoordinator.Trigger, resubmit: @escaping () -> Void
    ) {
        resubmit()
        let handle = BackgroundTaskHandle(task)
        let completion = CompletionGuard()
        let work = Task {
            let outcome = await runSync(reason: reason, trigger: trigger)
            if completion.markCompleted() { handle.task.setTaskCompleted(success: outcome != nil) }
        }
        handle.task.expirationHandler = {
            work.cancel()
            if completion.markCompleted() { handle.task.setTaskCompleted(success: false) }
        }
    }

    @MainActor
    private static func runSync(reason: String, trigger: SyncCoordinator.Trigger) async -> SyncOutcome? {
        await AppSyncEngine.shared?.run(reason: reason, trigger: trigger)
    }
}

/// See `handle`'s own doc comment for why this needs to exist at all.
private final class BackgroundTaskHandle: @unchecked Sendable {
    let task: BGTask
    init(_ task: BGTask) { self.task = task }
}

/// Guards `BGTask.setTaskCompleted` against being called twice — once when the sync finishes
/// normally, once if `expirationHandler` fires first — which Apple documents as undefined. A
/// plain lock rather than an actor: `expirationHandler` is not guaranteed to run on the main
/// actor, so an actor-isolated guard would need an `await` here regardless.
private final class CompletionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasCompleted = false

    func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasCompleted else { return false }
        hasCompleted = true
        return true
    }
}
