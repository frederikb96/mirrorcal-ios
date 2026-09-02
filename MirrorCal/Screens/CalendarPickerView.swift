import MirrorCalKit
import SwiftUI

/// A sheet listing every calendar EventKit can see, used for both the source and destination
/// pick. `onSelect` returns whether the pick was accepted — the destination side uses this to run
/// `DestinationGuard` and refuse a calendar that already holds foreign events, per row 26's own
/// requirement that this be refused before it is even configured.
struct CalendarPickerView: View {
    let title: String
    let calendars: [CalendarSummary]
    let onSelect: (CalendarSummary) -> CalendarPickerOutcome

    @Environment(\.dismiss) private var dismiss
    @State private var rejectionMessage: String?

    var body: some View {
        NavigationStack {
            List(calendars) { calendar in
                Button {
                    switch onSelect(calendar) {
                    case .accepted:
                        dismiss()
                    case .rejected(let message):
                        rejectionMessage = message
                    }
                } label: {
                    CalendarRow(calendar: calendar)
                        // A row laid out with a Spacer between two labels is hit-tested against
                        // what it draws, not its frame — this claims the whole row for the tap.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Can't use this calendar", isPresented: .constant(rejectionMessage != nil)) {
                Button("OK") { rejectionMessage = nil }
            } message: {
                Text(rejectionMessage ?? "")
            }
        }
    }
}

enum CalendarPickerOutcome {
    case accepted
    case rejected(message: String)
}

private struct CalendarRow: View {
    let calendar: CalendarSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(calendar.title)
                .font(.body)
            Text("\(calendar.accountName) · \(calendar.accountType)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !calendar.allowsContentModifications {
                Text("Read-only")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
