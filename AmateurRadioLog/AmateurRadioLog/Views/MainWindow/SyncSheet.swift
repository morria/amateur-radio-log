import SwiftUI
import SwiftData

/// The one sync screen, used by every provider.
///
/// It replaced three bespoke sheets that had drifted apart: QRZ had a
/// direction picker and progress, HamQTH and LoTW had prose and a differently
/// named button, and Wavelog had no sheet at all — it synced straight from
/// the sidebar, so its results surfaced in whichever other sheet happened to
/// be open. That is how a Wavelog run came to report its failures under a
/// heading reading "Sync QRZ.com".
///
/// One screen, one button, and the report is read from `syncReports[service]`
/// so a provider can only ever show its own outcome.
struct SyncSheet: View {
    let service: SyncService

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    /// True while *this* provider is the one syncing. A run of another
    /// provider must not make this sheet look busy.
    private var isSyncingThis: Bool { appState.activeSync == service }
    private var report: SyncReport? { appState.syncReports[service] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(service.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let date = appState.lastSyncDate(for: service) {
                        LabeledContent("Last synced") {
                            Text(date, format: .relative(presentation: .named))
                        }
                        .font(.caption)
                    }
                }

                if isSyncingThis {
                    progressSection
                } else if let report {
                    resultSection(report)
                }
            }
            .navigationTitle("Sync \(service.displayName)")
            #if os(macOS)
            .frame(width: 460, height: 420)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sync") {
                        appState.startSync(service, context: modelContext)
                    }
                    // Disabled during *any* sync: the engine runs one at a
                    // time, so offering the button would silently do nothing.
                    .disabled(appState.isSyncing)
                }
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        Section {
            if let progress = appState.syncProgress {
                ProgressView(value: Double(progress.done),
                             total: Double(max(progress.total, 1)))
                Text("\(progress.done) of \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let status = appState.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .cancel) {
                appState.cancelSync()
            } label: {
                Text("Cancel").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ report: SyncReport) -> some View {
        Section("Last Run") {
            Label {
                Text(report.summaryLine)
            } icon: {
                Image(systemName: report.didSucceed
                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(report.didSucceed ? .green : .red)
            }
            .font(.callout)
        }

        // Every failed record with the provider's own reason. This is the
        // whole point of the screen: "274 failed" is not actionable, but
        // "Differing locator FN30ar ... SKIPPED" tells you what to change.
        if !report.failures.isEmpty {
            Section("Failed Contacts") {
                ForEach(report.failures) { failure in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(failure.call)
                            .font(.caption.bold())
                        Text(failure.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }
}
