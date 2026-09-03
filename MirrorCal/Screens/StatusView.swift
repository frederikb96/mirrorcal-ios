import MirrorCalKit
import SwiftUI

struct StatusView: View {
    @Environment(AppSyncEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @State private var accessStatus: CalendarAccessStatus = .notDetermined
    @State private var resetCandidateCount: Int?
    @State private var isConfirmingReset = false

    var body: some View {
        NavigationStack {
            List {
                if accessStatus != .authorized {
                    Section {
                        PermissionBanner(status: accessStatus) {
                            accessStatus = await engine.requestCalendarAccess()
                        }
                    }
                }

                Section("Last sync") {
                    lastSyncContent
                }

                Section {
                    Button {
                        Task { await engine.run(reason: "manual (Sync Now)", trigger: .manual) }
                    } label: {
                        HStack {
                            Text("Sync Now")
                            if engine.isSyncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(engine.isSyncing || !engine.settings.isConfigured)
                    .accessibilityIdentifier("status.sync-now")
                }

                if let warning = engine.pendingRunawayConfirmation {
                    Section("This sync was refused") {
                        Label(
                            "It wants to create \(warning.creations) event(s), close to the "
                                + "\(warning.existingOwned) MirrorCal already has here. That usually means "
                                + "something is wrong — most likely that mirrored events aren't being "
                                + "recognised on the next sync — rather than a real bulk change.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                        Button("Create these events anyway", role: .destructive) {
                            Task {
                                await engine.run(
                                    reason: "manual (forced past runaway guard)", trigger: .manual, force: true)
                            }
                        }
                        .accessibilityIdentifier("status.force-sync")
                    }
                }

                Section("Recovery") {
                    Button(role: .destructive) {
                        resetCandidateCount = engine.resetCandidateCount()
                        isConfirmingReset = (resetCandidateCount ?? 0) > 0
                    } label: {
                        Text("Reset Mirror")
                    }
                    .disabled(engine.isSyncing || !engine.settings.isConfigured)
                    .accessibilityIdentifier("status.reset")
                    Label(
                        "Removes every event this install has mirrored into the destination "
                            + "calendar, then rebuilds it from scratch on the next sync. Use this if the "
                            + "mirror looks wrong and a normal sync isn't fixing it.",
                        systemImage: "arrow.counterclockwise"
                    )
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                }

                Section {
                    Label(
                        "Swiping MirrorCal away in the App Switcher stops background syncing until "
                            + "you reopen it — this is real iOS behaviour, not a bug.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                }
            }
            .navigationTitle("Status")
            .accessibilityIdentifier("screen.status")
        }
        .task { accessStatus = engine.calendarAccessStatus }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { accessStatus = engine.calendarAccessStatus }
        }
        // The count is fetched *before* this ever presents (see the button's action above), so
        // the confirmation always states a real number rather than a placeholder — a number is
        // the one thing that catches a wrong-calendar reset before it happens, not after.
        .confirmationDialog(
            "Delete \(resetCandidateCount ?? 0) event(s) from the destination calendar?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Delete \(resetCandidateCount ?? 0) event(s)", role: .destructive) {
                Task { await engine.performReset() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var lastSyncContent: some View {
        if let history = engine.lastHistory {
            LabeledContent("When", value: relativeDescription(history.at))
            LabeledContent("Reason", value: history.reason)
            if let outcome = history.outcome {
                LabeledContent("Created", value: "\(outcome.created)")
                LabeledContent("Updated", value: "\(outcome.updated)")
                LabeledContent("Deleted", value: "\(outcome.deleted)")
                LabeledContent("Unchanged", value: "\(outcome.unchanged)")
                if outcome.duplicatesRemoved > 0 {
                    LabeledContent("Duplicates removed", value: "\(outcome.duplicatesRemoved)")
                }
                if outcome.sourceCollisions > 0 {
                    LabeledContent("Source collisions", value: "\(outcome.sourceCollisions)")
                }
                if outcome.unstampableSourceEvents > 0 {
                    LabeledContent("Unstampable events", value: "\(outcome.unstampableSourceEvents)")
                }
            } else if let error = history.errorDescription {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } else {
            Text("No sync has run yet.")
                .foregroundStyle(.secondary)
        }
    }

    private func relativeDescription(_ date: Date) -> String {
        let now = Date()
        // `date` is `history.at`, captured earlier in the same run this reads it from — a few
        // milliseconds after `now` here is ordinary clock drift, not a sync that happened in the
        // future. Taken literally, `RelativeDateTimeFormatter` reads that gap as "in 0 seconds",
        // which is the single number on this screen that answers "is this thing working".
        guard now.timeIntervalSince(date) >= 1 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// One row per access state, each with its own copy and its own action — `.restricted` in
/// particular has no "Open Settings" action, because an MDM-restricted device has nothing there
/// for the person to change.
private struct PermissionBanner: View {
    let status: CalendarAccessStatus
    let onRequest: () async -> Void

    var body: some View {
        switch status {
        case .authorized:
            EmptyView()
        case .notDetermined:
            Button {
                Task { await onRequest() }
            } label: {
                Label("Grant calendar access", systemImage: "calendar.badge.plus")
            }
        case .writeOnly:
            Label(
                "Calendar access is write-only. MirrorCal has to read events back to reconcile — "
                    + "open Settings and change access to Full.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .denied:
            Label(
                "Calendar access was denied. Open Settings → MirrorCal → Calendars and allow Full Access.",
                systemImage: "xmark.circle"
            )
            .foregroundStyle(.red)
        case .restricted:
            Label(
                "Calendar access is restricted by this device's management profile. This cannot "
                    + "be changed from within the app.",
                systemImage: "lock"
            )
            .foregroundStyle(.red)
        }
    }
}
