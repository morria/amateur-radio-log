import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var showQRZSync = false
    @State private var showLoTWSync = false

    var body: some View {
        @Bindable var appState = appState
        List(selection: Binding<NavigationTab?>(
            get: { appState.selectedTab },
            set: { if let tab = $0 { appState.selectedTab = tab } }
        )) {
            Section("Views") {
                ForEach(NavigationTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }

            Section("Sync") {
                Button(action: { showQRZSync = true }) {
                    Label("Sync QRZ", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(action: { showLoTWSync = true }) {
                    Label("Sync LoTW", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            #if os(iOS)
            Section("Settings") {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
            #endif
        }
        .listStyle(.sidebar)
        .navigationTitle("Amateur Radio Log")
        .sheet(isPresented: $showQRZSync) {
            SyncConfigSheet(provider: "QRZ.com") { direction in
                Task { await appState.syncQRZ(context: modelContext, direction: direction) }
            }
        }
        .sheet(isPresented: $showLoTWSync) {
            SyncConfigSheet(provider: "LoTW") { direction in
                Task { await appState.syncLoTW(context: modelContext, direction: direction) }
            }
        }
    }
}

// MARK: - Sync Config Sheet

struct SyncConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let provider: String
    let onSync: (SyncDirection) -> Void

    @State private var direction: SyncDirection = .both

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Text(provider).font(.headline)
                }

                Section("Direction") {
                    Picker("Sync Direction", selection: $direction) {
                        ForEach(SyncDirection.allCases) { dir in
                            Text(dir.rawValue).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch direction {
                    case .upload:
                        Text("Upload local QSOs to \(provider).")
                            .font(.caption).foregroundStyle(.secondary)
                    case .download:
                        Text("Download QSOs from \(provider). Duplicates will be skipped.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .both:
                        Text("Upload local QSOs and download new QSOs from \(provider). Duplicates will be skipped.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if provider == "LoTW" {
                    Section {
                        Text("Note: LoTW upload sends unsigned ADIF. For full LoTW integration, use TQSL to sign and upload your ADIF files.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if appState.isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(appState.statusMessage ?? "Syncing...")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let status = appState.statusMessage, !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Sync \(provider)")
            #if os(macOS)
            .frame(width: 400, height: 320)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sync") {
                        onSync(direction)
                    }
                    .disabled(appState.isLoading)
                }
            }
        }
    }
}
