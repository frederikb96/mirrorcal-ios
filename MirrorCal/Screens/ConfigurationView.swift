import MirrorCalKit
import SwiftUI

struct ConfigurationView: View {
    @Environment(AppSyncEngine.self) private var engine
    @State private var settings = SyncSettings()
    @State private var sidecarSecretInput = ""
    @State private var newExcludedTitle = ""
    @State private var isPickingSource = false
    @State private var isPickingDestination = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Calendars") {
                    calendarRow(title: "Source", identifier: settings.sourceCalendarIdentifier) {
                        isPickingSource = true
                    }
                    calendarRow(title: "Destination", identifier: settings.destinationCalendarIdentifier) {
                        isPickingDestination = true
                    }
                }

                Section("Window") {
                    Stepper(
                        "Months back: \(settings.windowMonthsBack)", value: $settings.windowMonthsBack, in: 1...24)
                    Stepper(
                        "Months forward: \(settings.windowMonthsForward)", value: $settings.windowMonthsForward,
                        in: 1...24)
                }

                Section("What gets copied") {
                    Picker("Title", selection: $settings.titlePolicyRawValue) { policyOptions }
                    Picker("Description", selection: $settings.descriptionPolicyRawValue) { policyOptions }
                    Picker("Location", selection: $settings.locationPolicyRawValue) { policyOptions }
                }

                Section("Excluded titles") {
                    excludedTitlesList
                    HStack {
                        TextField("Title to exclude", text: $newExcludedTitle)
                        Button("Add") {
                            guard !newExcludedTitle.isEmpty else { return }
                            settings.excludedTitles.insert(newExcludedTitle)
                            newExcludedTitle = ""
                        }
                        .disabled(newExcludedTitle.isEmpty)
                    }
                }

                Section("Push sidecar") {
                    TextField("Host (https://...)", text: $settings.sidecarHost)
                        #if os(iOS)
                            .keyboardType(.URL)
                        #endif
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Shared secret", text: $sidecarSecretInput)
                    Button("Save Secret") {
                        guard !sidecarSecretInput.isEmpty else { return }
                        SyncSecretStore.save(sidecarSecretInput)
                        settings.hasSidecarSecret = true
                        sidecarSecretInput = ""
                    }
                    .disabled(sidecarSecretInput.isEmpty)
                    if settings.hasSidecarSecret {
                        Text("A shared secret is saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $settings.isEnabled)
                        .disabled(!settings.isConfigured)
                    if !settings.isConfigured {
                        Text("Pick both a source and destination calendar first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Configuration")
            .accessibilityIdentifier("screen.configuration")
            .onChange(of: settings) { _, newValue in
                engine.updateSettings(newValue)
            }
            .task { settings = engine.settings }
            .sheet(isPresented: $isPickingSource) {
                CalendarPickerView(title: "Source Calendar", calendars: engine.availableCalendars()) { calendar in
                    settings.sourceCalendarIdentifier = calendar.id
                    return .accepted
                }
            }
            .sheet(isPresented: $isPickingDestination) {
                CalendarPickerView(title: "Destination Calendar", calendars: engine.availableCalendars()) { calendar in
                    switch engine.validateDestinationCandidate(calendarIdentifier: calendar.id) {
                    case .success:
                        settings.destinationCalendarIdentifier = calendar.id
                        return .accepted
                    case .failure(.containsUnstampedEvents(let count)):
                        return .rejected(
                            message:
                                "This calendar already has \(count) event(s) MirrorCal didn't create. "
                                + "Pick an empty calendar dedicated to the mirror.")
                    case .failure(.unableToVerify):
                        return .rejected(
                            message: "Couldn't check this calendar for existing events — try again.")
                    }
                }
            }
        }
    }

    private var policyOptions: some View {
        ForEach(SyncSettings.FieldPolicyRawValue.allCases, id: \.self) { option in
            Text(label(for: option)).tag(option)
        }
    }

    @ViewBuilder
    private var excludedTitlesList: some View {
        let sorted = settings.excludedTitles.sorted()
        ForEach(sorted, id: \.self) { title in
            Text(title)
        }
        .onDelete { indices in
            for index in indices { settings.excludedTitles.remove(sorted[index]) }
        }
    }

    private func label(for policy: SyncSettings.FieldPolicyRawValue) -> String {
        switch policy {
        case .copy: "Copy"
        case .drop: "Drop"
        case .busyOnly: "Replace with \"Busy\""
        }
    }

    @ViewBuilder
    private func calendarRow(title: String, identifier: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(calendarName(for: identifier))
                    .foregroundStyle(.secondary)
            }
            // A row laid out with a Spacer between two labels is hit-tested against what it
            // draws, not its frame — this claims the whole row for the tap.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func calendarName(for identifier: String?) -> String {
        guard let identifier, let match = engine.availableCalendars().first(where: { $0.id == identifier }) else {
            return "Not set"
        }
        return match.title
    }
}
