import AppIntents
import MirrorCalKit

/// Lets Freddy build Shortcuts personal automations (07:30, 12:30, on "when I open Calendar",
/// and so on) that run a sync without opening the app — `openAppWhenRun = false` is what makes
/// that possible. Personal automations are known to be unreliable in practice, so this raises
/// the floor on how often a sync happens rather than being the trigger anything depends on.
struct SyncCalendarIntent: AppIntent {
    static var title: LocalizedStringResource { "Sync MirrorCal" }
    static var description: IntentDescription {
        IntentDescription("Mirrors calendar events now, the same as opening the app.")
    }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let engine = AppSyncEngine.shared else {
            return .result(dialog: "MirrorCal isn't running yet — open it once first.")
        }
        guard let outcome = await engine.run(reason: "shortcut automation", trigger: .shortcut) else {
            return .result(dialog: "MirrorCal sync failed — check the log in the app.")
        }
        return .result(
            dialog:
                "Synced: \(outcome.created) created, \(outcome.updated) updated, \(outcome.deleted) deleted.")
    }
}

struct MirrorCalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncCalendarIntent(),
            phrases: ["Sync \(.applicationName)", "Sync my calendar with \(.applicationName)"],
            shortTitle: "Sync Calendar",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
