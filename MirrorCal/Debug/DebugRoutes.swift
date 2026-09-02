#if DEBUG

    import Foundation
    import MirrorCalKit

    /// The app's debug endpoints, `#if DEBUG` end to end.
    ///
    /// Reachable from the build host because a simulator shares the Mac's network stack:
    /// `curl 127.0.0.1:8765/health`.
    enum DebugRoutes {

        static func make() -> DebugRouter {
            var router = DebugRouter()

            router.register("GET", "/health") { _ in
                .encoding([
                    "status": "ok",
                    "bundle": Bundle.main.bundleIdentifier ?? "?",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                ])
            }

            // What the app currently thinks: access status, whether it's configured/enabled, and
            // the last sync's outcome — a device probe worth having before anything else, so a
            // stuck app can be diagnosed from the calendars and permissions it actually sees.
            router.register("GET", "/state") { _ in
                guard let snapshot = DebugBridgeSync.awaitMainActor({ AppStateSnapshot.current() }) else {
                    return .message("timed out reading app state", status: 504)
                }
                return .encoding(snapshot)
            }

            // Every calendar EventKit can see, with the capability flags a configuration decision
            // needs — real EventKit or the fixture pair, whichever this launch is running.
            router.register("GET", "/calendars") { _ in
                guard
                    let calendars = DebugBridgeSync.awaitMainActor({
                        AppSyncEngine.shared?.availableCalendars() ?? []
                    })
                else { return .message("timed out reading calendars", status: 504) }
                return .encoding(calendars)
            }

            router.register("GET", "/log") { request in
                let limit = request.query["limit"].flatMap(Int.init) ?? 200
                let entries = DebugLogBuffer.shared.snapshot(limit: limit)
                return .encoding(entries.map(LogEntryPayload.init))
            }

            // Triggers a real sync and waits for its outcome, so a CI run or a curl call gets the
            // answer in one round trip. A longer timeout than the other routes: a first sync on a
            // busy calendar is meant to take a while.
            router.register("POST", "/sync") { _ in
                guard
                    let outcome = DebugBridgeSync.awaitMainActor(
                        timeout: 90,
                        { await AppSyncEngine.shared?.run(reason: "debug bridge", trigger: .manual) })
                else { return .message("timed out running sync", status: 504) }
                guard let outcome else { return .message("sync failed — see /log", status: 500) }
                return .encoding(SyncOutcomePayload(outcome))
            }

            // A live diff against the destination calendar, computed but not applied — so drift
            // can be *seen* directly rather than only inferred from a log line after the fact.
            router.register("GET", "/drift") { _ in
                guard let plan = DebugBridgeSync.awaitMainActor({ AppSyncEngine.shared?.computeDrift() })
                else { return .message("timed out computing drift", status: 504) }
                guard let plan else {
                    return .message("drift unavailable — check calendar access and configuration", status: 200)
                }
                return .encoding(DriftPayload(plan: plan))
            }

            // The current top-level screen, and a route to change it — what lets `Mac`'s
            // screenshot step drive the app with no `idb` and no human, per the "prefer the
            // bridge over pixels" doctrine applied to navigation itself.
            router.register("GET", "/screen") { _ in
                guard let screen = DebugBridgeSync.awaitMainActor({ AppScreenTracker.shared.current })
                else { return .message("timed out reading screen", status: 504) }
                return .encoding(["screen": screen.rawValue])
            }

            router.register("POST", "/navigate") { request in
                guard let body = try? JSONDecoder().decode([String: String].self, from: request.body),
                    let name = body["screen"], let screen = AppScreenTracker.Screen(rawValue: name)
                else {
                    return .message(
                        "body must be {\"screen\": \"status\"|\"configuration\"|\"log\"}", status: 400)
                }
                _ = DebugBridgeSync.awaitMainActor({ AppScreenTracker.shared.current = screen })
                return .encoding(["screen": screen.rawValue])
            }

            return router
        }
    }

    struct AppStateSnapshot: Codable, Sendable {
        let fixtureMode: Bool
        let calendarAccessStatus: String
        let isEnabled: Bool
        let isConfigured: Bool
        let sourceCalendarID: String?
        let destinationCalendarID: String?
        let lastSyncReason: String?
        let lastSyncAt: String?
        let lastSyncSucceeded: Bool?

        @MainActor
        static func current() -> AppStateSnapshot {
            let engine = AppSyncEngine.shared
            let settings = engine?.settings ?? SyncSettings()
            let history = engine?.lastHistory
            return AppStateSnapshot(
                fixtureMode: MirrorCalApp.isFixtureMode,
                calendarAccessStatus: String(describing: engine?.calendarAccessStatus ?? .notDetermined),
                isEnabled: settings.isEnabled,
                isConfigured: settings.isConfigured,
                sourceCalendarID: settings.sourceCalendarIdentifier,
                destinationCalendarID: settings.destinationCalendarIdentifier,
                lastSyncReason: history?.reason,
                lastSyncAt: history.map { ISO8601DateFormatter().string(from: $0.at) },
                lastSyncSucceeded: history?.succeeded
            )
        }
    }

    struct SyncOutcomePayload: Codable, Sendable {
        let created: Int
        let updated: Int
        let deleted: Int
        let unchanged: Int
        let duplicatesRemoved: Int

        init(_ outcome: SyncOutcome) {
            created = outcome.created
            updated = outcome.updated
            deleted = outcome.deleted
            unchanged = outcome.unchanged
            duplicatesRemoved = outcome.duplicatesRemoved
        }
    }

    struct DriftPayload: Codable, Sendable {
        let creations: Int
        let updates: Int
        let deletions: Int
        let unchanged: Int
        let isEmpty: Bool

        init(plan: SyncPlan) {
            creations = plan.creations.count
            updates = plan.updates.count
            deletions = plan.deletions.count
            unchanged = plan.unchanged.count
            isEmpty = plan.isEmpty
        }
    }

    struct LogEntryPayload: Codable, Sendable {
        let level: String
        let category: String
        let message: String
        let at: String

        init(_ entry: DebugLogBuffer.Entry) {
            level = entry.level.rawValue
            category = entry.category
            message = entry.message
            at = ISO8601DateFormatter().string(from: entry.at)
        }
    }

#endif
