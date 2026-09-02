import EventKit
import Foundation
import MirrorCalKit

/// Watches `.EKEventStoreChanged` while the app is foregrounded and triggers a sync — the
/// "calendar-changed notification while foregrounded" trigger row 32 names distinctly from a
/// plain app-becomes-active launch. Both map to `SyncCoordinator.Trigger.foreground` (there is no
/// separate case for this, and `MirrorCalKit` is left alone rather than widened for one caller);
/// what actually distinguishes them is the `reason` string this passes to `AppSyncEngine.run`,
/// which is what the Status and Log screens display.
///
/// Debounced and self-write-guarded — the defence against the exact loop row 13 names: on
/// Android, the destination's own write fired the change observer, which fired another sync,
/// roughly every four seconds indefinitely. This app's engine naturally settles after one extra
/// round (a second `plan()` call sees only `unchanged` content and stages nothing), but nothing
/// here should depend on that alone — `lastCommitAt` suppresses a notification that arrives
/// inside this app's own recent write window, and `minimumInterval` caps how often this observer
/// can start a sync on its own regardless.
@MainActor
final class CalendarChangeObserver {
    /// `NSObjectProtocol` is not `Sendable`. `start()`/`stop()` are driven by `scenePhase`
    /// transitions rather than by `deinit`, which sidesteps needing `nonisolated(unsafe)` here
    /// rather than fighting it.
    private var token: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var lastTriggeredAt: Date?

    private let minimumInterval: TimeInterval
    private let selfWriteGracePeriod: TimeInterval
    private let debounce: Duration

    init(
        minimumInterval: TimeInterval = 20, selfWriteGracePeriod: TimeInterval = 5,
        debounce: Duration = .seconds(2)
    ) {
        self.minimumInterval = minimumInterval
        self.selfWriteGracePeriod = selfWriteGracePeriod
        self.debounce = debounce
    }

    func start() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleChange() }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func handleChange() {
        if let lastCommitAt = AppSyncEngine.shared?.lastCommitAt,
            Date().timeIntervalSince(lastCommitAt) < selfWriteGracePeriod
        {
            DebugLogBuffer.shared.append(
                .debug, "calendar-observer", "change notification ignored — inside this app's own write window")
            return
        }
        if let lastTriggeredAt, Date().timeIntervalSince(lastTriggeredAt) < minimumInterval {
            return
        }

        // Coalesces a burst of notifications (EventKit can post several for one underlying
        // change) into one sync, started slightly after the last one arrives.
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.lastTriggeredAt = Date()
            _ = await AppSyncEngine.shared?.run(reason: "calendar changed (foreground)", trigger: .foreground)
        }
    }
}
