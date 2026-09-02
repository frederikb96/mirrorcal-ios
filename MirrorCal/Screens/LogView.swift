import MirrorCalKit
import SwiftUI
import UIKit

/// A TestFlight build has no debugger attached — this is the only way Freddy can ever tell us
/// what went wrong on his own phone, so the share button is load-bearing, not a nicety.
struct LogView: View {
    @State private var entries: [DebugLogBuffer.Entry] = []
    @State private var isSharePresented = false

    var body: some View {
        NavigationStack {
            List(Array(entries.reversed().enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.level.rawValue.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(color(for: entry.level))
                        Text(entry.category)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.at, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .font(.footnote)
                }
            }
            .navigationTitle("Log")
            .accessibilityIdentifier("screen.log")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSharePresented = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("log.share")
                }
            }
            .task {
                // A plain polling loop rather than a Combine timer: `.task` is cancelled
                // automatically when the view disappears, which a stored `Timer.publish`
                // subscription needs an explicit `import Combine` and its own teardown for.
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            .sheet(isPresented: $isSharePresented) {
                ShareSheet(items: [logText()])
            }
        }
    }

    private func refresh() {
        entries = DebugLogBuffer.shared.snapshot(limit: 500)
    }

    private func logText() -> String {
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            "\(formatter.string(from: entry.at)) [\(entry.level.rawValue)] \(entry.category): \(entry.message)"
        }.joined(separator: "\n")
    }

    private func color(for level: DebugLogBuffer.Level) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
