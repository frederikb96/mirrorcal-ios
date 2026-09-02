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
    /// describes.
    public private(set) var lastCommitAt: Date?

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
    @discardableResult
    public func run(reason: String, trigger: SyncCoordinator.Trigger) async -> SyncOutcome? {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let outcome = try await coordinator.requestSync(trigger: trigger)
            historyStore.recordSuccess(reason: reason, outcome: outcome)
            lastHistory = historyStore.loadLast()
            DebugLogBuffer.shared.append(
                .info, "sync",
                "\(reason): created \(outcome.created), updated \(outcome.updated), "
                    + "deleted \(outcome.deleted), unchanged \(outcome.unchanged), "
                    + "duplicates removed \(outcome.duplicatesRemoved)")
            return outcome
        } catch {
            historyStore.recordFailure(reason: reason, error: String(describing: error))
            lastHistory = historyStore.loadLast()
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
        let (source, destination, supportedAvailabilities) = try resolveStores()
        let configuration = settings.configuration(supportedDestinationAvailabilities: supportedAvailabilities)
        let window = settings.window()
        let cache = SyncCacheFile.load()
        let result = try engine.synchronize(
            source: source, destination: destination, cache: cache, configuration: configuration, window: window)
        SyncCacheFile.save(result.cache)
        lastCommitAt = Date()
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
    public func validateDestinationCandidate(calendarIdentifier: String) -> Result<Void, DestinationGuardError> {
        #if DEBUG
            guard !fixtureMode else { return .success(()) }
        #endif
        guard let calendar = store.calendar(withIdentifier: calendarIdentifier) else { return .success(()) }
        let wideWindow = DateInterval(
            start: Date().addingTimeInterval(-2 * 365 * 24 * 3600),
            end: Date().addingTimeInterval(2 * 365 * 24 * 3600))
        guard let events = try? EventKitDestinationStore(store: store, calendar: calendar).events(in: wideWindow)
        else { return .success(()) }
        return DestinationGuard.validateForConfiguration(existingEvents: events)
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
