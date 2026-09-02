import MirrorCalKit
import SwiftUI

struct StatusView: View {
    @Environment(AppSyncEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @State private var accessStatus: CalendarAccessStatus = .notDetermined

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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
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
