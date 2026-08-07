import SwiftUI
import JarvisTools

/// Safety controls and the audit trail (spec §7).
@MainActor
struct ActivitySettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var entries: [AuditLog.Entry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Safety") {
                    Toggle("Dry run — describe actions without doing them", isOn: $appState.dryRunEnabled)
                    Text("Every tool reports what it would have done and changes nothing. "
                         + "Useful while testing new behaviour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Search the web for current information", isOn: $appState.webSearchEnabled)
                    Text("Lets Claude look things up mid-answer. Queries leave this Mac, "
                         + "and a turn that searches takes a few seconds longer to start speaking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 210)

            Divider()

            HStack {
                Text("Recent tool activity")
                    .font(.headline)
                Spacer()
                Button("Refresh") { Task { await load() } }
                Button("Reveal log") {
                    Task { NSWorkspace.shared.activateFileViewerSelecting([await AuditLog.shared.fileURL]) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if entries.isEmpty {
                Text("Nothing yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Self.color(for: entry.outcome))
                                .frame(width: 7, height: 7)
                            Text(entry.tool)
                                .font(.system(.body, design: .monospaced))
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if entry.requiredConfirmation {
                                Image(systemName: entry.confirmed == true
                                      ? "checkmark.shield" : "xmark.shield")
                                    .foregroundStyle(.secondary)
                                    .help(entry.confirmed == true ? "Confirmed" : "Declined")
                            }
                            Text("\(entry.durationMS) ms")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .task { await load() }
    }

    private static func color(for outcome: String) -> Color {
        switch outcome {
        case "succeeded": .green
        case "failed": .red
        case "declined": .orange
        default: .secondary
        }
    }

    private func load() async {
        entries = await AuditLog.shared.recent(limit: 200)
    }
}
