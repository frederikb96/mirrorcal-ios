import EventKit
import Foundation
import MirrorCalKit
import Observation

public enum AppSyncEngineError: Error, Sendable, Equatable {
    case deallocated
    case notConfigured
    case calendarAccessDenied
    case calendarNotFound
}

/// Holds a weak back-reference to `AppSyncEngine`, so `SyncCoordinator`'s closures can reach it
/// without capturing `self` during `init` — Swift refuses any use of `self` before every stored
/// property is set, and `coordinator` has to be built *during* `init` because nothing here is
/// `lazy` (see the note on `coordinator` below for why). `weak` breaks the retain cycle this would
/// otherwise form: the engine owns `coordinator`, `coordinator` owns this box.
///
/// `@unchecked Sendable`: `SyncCoordinator`'s `perform` closure must itself be `@Sendable`, so
/// everything it captures — this box included — has to be. `engine` is written exactly once, on
/// the main actor, immediately after construction, and never mutated again; every later read
/// happens off that actor (from `SyncCoordinator`'s own isolation), but a weak reference read is
/// safe from any thread by construction in the Swift runtime, which is what the annotation here
/// asserts rather than assumes silently.
private final class AppSyncEngineBox: @unchecked Sendable {
    weak var engine: AppSyncEngine?
}

/// The app's own front end onto `SyncEngine`/`SyncCoordinator` — everything a trigger, a screen,
/// or a debug route needs, in one place: resolves the configured calendars (real EventKit or the
/// fixture pair), persists settings/cache/history, and records every run to the log.
///
/// `@MainActor`: this is what every trigger and every view touches, and EventKit's own store is
/// not safe to hit from more than one place at a time — funnelling everything through one actor is
/// simpler than auditing each call site for its own synchronization.
@MainActor
@Observable
public final class AppSyncEngine {
    /// A static back door rather than dependency injection everywhere, because `AppIntent.perform()`
    /// and the debug bridge's route handlers are both instantiated fresh by the system with no
    /// constructor argument to receive one through.
    public static weak var shared: AppSyncEngine?

    @ObservationIgnored private let store: EKEventStore
    @ObservationIgnored private let settingsStore: SyncSettingsStore
    @ObservationIgnored private let historyStore: SyncHistoryStore
    @ObservationIgnored private let engine = SyncEngine()
    @ObservationIgnored private let fixtureMode: Bool
    #if DEBUG
        // `FixtureCalendarStore` and the `EventFixtures` it reads are both `#if DEBUG` — a
        // Release build of this app target never sees this type at all, so its declaration and
        // every use of it have to be guarded the same way, not merely the call sites.
        @ObservationIgnored private let fixtureStores:
            (
                source: any SourceCalendarReading, destination: any DestinationCalendarStore
            )?
    #endif
    /// Not `lazy`: `@Observable`'s macro rewrites stored properties into registrar-backed
    /// accessors, an interaction with `lazy` storage that has never been run through a Mac here —
    /// safer to sidestep it than to depend on it working, per the "unverified without a device"
    /// discipline this app is built under. `AppSyncEngineBox` is what makes a non-lazy `let`
    /// possible instead.
    @ObservationIgnored private let coordinator: SyncCoordinator

    public private(set) var settings: SyncSettings
    public private(set) var lastHistory: SyncHistoryEntry?
    public private(set) var isSyncing = false
    /// Set right after a sync that actually committed something — `CalendarChangeObserver` reads
    /// this to suppress the `EKEventStoreChanged` notification the app's own write is expected to
    /// provoke, which is the guard against the self-triggering loop that type's own doc comment
    /// describes. Left unset by a no-op sync, matching what the name says rather than what "ran
    /// most recently" would.
    public private(set) var lastCommitAt: Date?
    /// A run refused by `CreationCircuitBreaker`, waiting for a conscious decision — `nil` the
    /// rest of the time. The Status screen reads this to offer "create these events anyway"
    /// rather than leaving the run silently blocked; `run(force: true)` is what clears it.
    public private(set) var pendingRunawayConfirmation: (creations: Int, existingOwned: Int)?
    /// Consumed by `performSync`, which reads and resets it the moment a run starts — read from
    /// `run(force:)` rather than threaded through `SyncCoordinator.Trigger`, which carries no
    /// per-call payload. The gap between setting this and it being read is essentially zero (both
    /// happen on this actor, one call apart), and a forced run is only ever pressed once a
    /// previous run has already finished and `isSyncing` is false, so a coalesced run picking it
    /// up by mistake is not a realistic race in practice.
    @ObservationIgnored private var forceNextSync = false

    public init(
        store: EKEventStore = EKEventStore(),
        settingsStore: SyncSettingsStore = SyncSettingsStore(),
        historyStore: SyncHistoryStore = SyncHistoryStore(),
        fixtureMode: Bool = false
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.fixtureMode = fixtureMode
        self.settings = settingsStore.load()
        self.lastHistory = historyStore.loadLast()
        #if DEBUG
            self.fixtureStores = fixtureMode ? FixtureCalendarStore.makePair() : nil
        #endif

        let box = AppSyncEngineBox()
        self.coordinator = SyncCoordinator(
            perform: { trigger in
                guard let engine = box.engine else { throw AppSyncEngineError.deallocated }
                return try await engine.performSync(trigger: trigger)
            },
            record: { event in AppSyncEngine.logCoordinatorEvent(event) }
        )

        // Every stored property above is set; `self` is fully initialized from here on.
        box.engine = self
        AppSyncEngine.shared = self
    }

    // MARK: - Running a sync

    /// The one entry point every trigger calls. `reason` is the human-readable log line — every
    /// trigger records a distinct one, at a finer grain than `trigger` itself distinguishes;
    /// `trigger` is what `SyncCoordinator` coalesces on.
    ///
    /// `force` is the conscious escape hatch past `CreationCircuitBreaker`: it defaults to false
    /// for every ordinary caller, and the only call site that ever passes true is the Status
    /// screen's "create these events anyway" button, offered after `pendingRunawayConfirmation`
    /// is set by exactly this kind of refusal.
    @discardableResult
    public func run(reason: String, trigger: SyncCoordinator.Trigger, force: Bool = false) async -> SyncOutcome? {
        isSyncing = true
        defer { isSyncing = false }
        forceNextSync = force
        do {
            let outcome = try await coordinator.requestSync(trigger: trigger)
            historyStore.recordSuccess(reason: reason, outcome: outcome)
            lastHistory = historyStore.loadLast()
            pendingRunawayConfirmation = nil
            DebugLogBuffer.shared.append(.info, "sync", "\(reason): \(Self.logSummary(outcome))")
            return outcome
        } catch {
            historyStore.recordFailure(reason: reason, error: String(describing: error))
            lastHistory = historyStore.loadLast()
            if case SyncApplyError.suspectedRunaway(let creations, let existingOwned) = error {
                pendingRunawayConfirmation = (creations: creations, existingOwned: existingOwned)
            }
            DebugLogBuffer.shared.append(.error, "sync", "\(reason) failed: \(error)")
            return nil
        }
    }

    /// The actual work, run inside `SyncCoordinator`'s single-flight machinery — never called
    /// directly from outside this type. A trigger that is not `.manual` while sync is disabled is
    /// refused rather than silently skipped-but-reported-successful, so a disabled app never shows
    /// a phantom "last synced" time it did not earn.
    private func performSync(trigger: SyncCoordinator.Trigger) async throws -> SyncOutcome {
        guard settings.isConfigured, settings.isEnabled || trigger == .manual else {
            throw AppSyncEngineError.notConfigured
        }
        let force = forceNextSync
        forceNextSync = false
        let (source, destination, supportedAvailabilities) = try resolveStores()
        let configuration = settings.configuration(supportedDestinationAvailabilities: supportedAvailabilities)
        let window = settings.window()
        let cache = SyncCacheFile.load()
        let result = try engine.synchronize(
            source: source, destination: destination, cache: cache, configuration: configuration, window: window,
            destinationWindow: Self.padded(window), force: force)
        SyncCacheFile.save(result.cache)
        if result.outcome.created > 0 || result.outcome.updated > 0 || result.outcome.deleted > 0 {
            lastCommitAt = Date()
        }
        return result.outcome
    }

    /// A dry run for the debug bridge's `/drift` route: what `plan()` would decide right now,
    /// without applying it — a live diff against the destination calendar rather than anything
    /// remembered, which is the kind of visibility the app this ports from never had.
    public func computeDrift() -> SyncPlan? {
        guard let (source, destination, supportedAvailabilities) = try? resolveStores() else { return nil }
        let window = settings.window()
        guard let sourceEvents = try? source.events(in: window),
            let destinationEvents = try? destination.events(in: window)
        else { return nil }
        let configuration = settings.configuration(supportedDestinationAvailabilities: supportedAvailabilities)
        return engine.plan(source: sourceEvents, destination: destinationEvents, configuration: configuration)
    }

    private func resolveStores() throws -> (
        source: any SourceCalendarReading, destination: any DestinationCalendarStore,
        supportedAvailabilities: Set<EventAvailability>
    ) {
        #if DEBUG
            if fixtureMode, let fixtureStores {
                return (fixtureStores.source, fixtureStores.destination, Set(EventAvailability.allCases))
            }
        #endif
        guard calendarAccessStatus == .authorized else { throw AppSyncEngineError.calendarAccessDenied }
        guard let sourceIdentifier = settings.sourceCalendarIdentifier,
            let destinationIdentifier = settings.destinationCalendarIdentifier,
            let sourceCalendar = store.calendar(withIdentifier: sourceIdentifier),
            let destinationCalendar = store.calendar(withIdentifier: destinationIdentifier)
        else { throw AppSyncEngineError.calendarNotFound }

        return (
            EventKitSourceCalendar(store: store, calendar: sourceCalendar),
            EventKitDestinationStore(store: store, calendar: destinationCalendar),
            EventKitCalendarCatalog.supportedAvailabilities(destinationCalendar)
        )
    }

    // MARK: - Settings

    /// Transitioning `isEnabled` from off to on runs one sync immediately, in the foreground — a
    /// first sync on a busy calendar is too large to fit a `BGAppRefreshTask`'s ~30-second budget,
    /// so the big burst runs while the app is on screen and unconstrained, and ordinary background
    /// runs afterward are small diffs.
    public func updateSettings(_ newValue: SyncSettings) {
        let wasEnabled = settings.isEnabled
        settings = newValue
        settingsStore.save(newValue)
        if newValue.isEnabled, !wasEnabled, newValue.isConfigured {
            Task {
                await MirrorCalAppDelegate.requestAuthorizationIfNeeded()
                await self.run(reason: "initial sync (just enabled)", trigger: .manual)
            }
        }
    }

    /// Called once, when a destination calendar is chosen — never during an ordinary sync, per
    /// `DestinationGuard`'s own doc comment. Scoped to a wide, fixed window independent of the
    /// configured sync window: the question is "does this calendar already hold foreign events at
    /// all", not "within the range this app happens to be configured to mirror right now".
    ///
    /// A calendar that cannot even be read is refused (`.unableToVerify`), not treated as clean —
    /// "clean" is a claim about content this never got to see, and reporting success anyway is
    /// exactly the shape of guard that gets trusted later without having checked anything.
    public func validateDestinationCandidate(calendarIdentifier: String) -> Result<Int, DestinationGuardError> {
        #if DEBUG
            guard !fixtureMode else { return .success(0) }
        #endif
        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else {
            return .failure(.unableToVerify)
        }
        let wideWindow = Self.padded(DateInterval(start: Date(), end: Date()))
        guard let events = try? EventKitDestinationStore(store: store, calendar: calendar).events(in: wideWindow)
        else { return .failure(.unableToVerify) }

        let configuration = settings.configuration(supportedDestinationAvailabilities: [])
        let result = DestinationGuard.validateForConfiguration(existingEvents: events, configuration: configuration)
        if case .success(let foreignCount) = result, foreignCount > 0 {
            DebugLogBuffer.shared.append(
                .info, "destination-guard",
                "picked calendar already holds \(foreignCount) event(s) stamped by another installation")
        }
        return result
    }

    // MARK: - Reset

    /// How many of this installation's own events a reset would remove right now — computed
    /// without applying anything, so the UI can show the count *before* asking for confirmation
    /// rather than after. Scanned over the same widened window `performSync` uses for the
    /// destination side, for the same reason: reset must reach an event a narrow window would
    /// otherwise strand.
    public func resetCandidateCount() -> Int? {
        guard let (_, destination, supportedAvailabilities) = try? resolveStores() else { return nil }
        let configuration = settings.configuration(supportedDestinationAvailabilities: supportedAvailabilities)
        guard let events = try? destination.events(in: Self.padded(settings.window())) else { return nil }
        return engine.resetPlan(destination: events, configuration: configuration).count
    }

    /// Deletes every event this installation has ever written to the configured destination —
    /// the recovery path for the reinstall-duplication case above, and for anything else that has
    /// gone wrong in a way nobody anticipated. Never called directly by a trigger; only ever by a
    /// person, after `resetCandidateCount` has already told them how many events this will remove.
    @discardableResult
    public func performReset() async -> Int? {
        guard let (_, destination, supportedAvailabilities) = try? resolveStores() else { return nil }
        let configuration = settings.configuration(supportedDestinationAvailabilities: supportedAvailabilities)
        guard let events = try? destination.events(in: Self.padded(settings.window())) else { return nil }
        do {
            let removed = try engine.applyReset(destination: events, configuration: configuration, to: destination)
            if removed > 0 { lastCommitAt = Date() }
            historyStore.recordSuccess(
                reason: "reset",
                outcome: SyncOutcome(created: 0, updated: 0, deleted: removed, unchanged: 0, duplicatesRemoved: 0))
            lastHistory = historyStore.loadLast()
            DebugLogBuffer.shared.append(.warning, "reset", "removed \(removed) event(s) written by this installation")
            return removed
        } catch {
            historyStore.recordFailure(reason: "reset", error: String(describing: error))
            lastHistory = historyStore.loadLast()
            DebugLogBuffer.shared.append(.error, "reset", "failed: \(error)")
            return nil
        }
    }

    /// A generously padded interval around `window` — used wherever a check needs "does the
    /// destination hold something far outside the range this app is configured to look at
    /// currently" rather than "within it": the destination side of an ordinary sync (so an aged-
    /// out mirror is still reachable by the delete pass), the destination-candidate guard, and a
    /// reset's own scan.
    private static func padded(_ window: DateInterval, by padding: TimeInterval = 2 * 365 * 24 * 3600) -> DateInterval {
        DateInterval(start: window.start.addingTimeInterval(-padding), end: window.end.addingTimeInterval(padding))
    }

    // MARK: - Calendar access

    public var calendarAccessStatus: CalendarAccessStatus {
        #if DEBUG
            if fixtureMode { return .authorized }
        #endif
        return EventKitPermission.currentStatus()
    }

    @discardableResult
    public func requestCalendarAccess() async -> CalendarAccessStatus {
        #if DEBUG
            if fixtureMode { return .authorized }
        #endif
        return await EventKitPermission.requestFullAccess(using: store)
    }

    public func availableCalendars() -> [CalendarSummary] {
        #if DEBUG
            if fixtureMode { return FixtureCalendarStore.calendarSummaries }
        #endif
        return EventKitCalendarCatalog.calendars(store: store)
    }

    // MARK: - Logging

    /// The counts a normal sync always has, plus the two that only appear when the source data
    /// itself was ambiguous — appended only when nonzero, so an ordinary sync's log line reads
    /// exactly as it always has.
    nonisolated private static func logSummary(_ outcome: SyncOutcome) -> String {
        var summary =
            "created \(outcome.created), updated \(outcome.updated), "
            + "deleted \(outcome.deleted), unchanged \(outcome.unchanged), "
            + "duplicates removed \(outcome.duplicatesRemoved)"
        if outcome.sourceCollisions > 0 {
            summary += ", source collisions \(outcome.sourceCollisions)"
        }
        if outcome.unstampableSourceEvents > 0 {
            summary += ", unstampable events \(outcome.unstampableSourceEvents)"
        }
        return summary
    }

    nonisolated private static func logCoordinatorEvent(_ event: SyncCoordinator.Event) {
        switch event {
        case .started(let trigger):
            DebugLogBuffer.shared.append(.debug, "sync-coordinator", "started (\(trigger))")
        case .coalesced(let trigger):
            DebugLogBuffer.shared.append(.debug, "sync-coordinator", "coalesced (\(trigger))")
        case .finished(let trigger, let outcome):
            DebugLogBuffer.shared.append(
                .debug, "sync-coordinator",
                "finished (\(trigger)): +\(outcome.created) ~\(outcome.updated) -\(outcome.deleted)")
        case .failed(let trigger, let message):
            DebugLogBuffer.shared.append(.warning, "sync-coordinator", "failed (\(trigger)): \(message)")
        }
    }
}
