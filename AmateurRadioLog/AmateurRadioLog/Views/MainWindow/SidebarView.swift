import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selectedTab: NavigationTab
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var allQSOs: [QSO]

    var body: some View {
        List(selection: $selectedTab) {
            Section("Views") {
                ForEach(NavigationTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }

            Section("Summary") {
                Label("\(allQSOs.count) QSOs", systemImage: "tray.full")
            }

            Section("Sync") {
                Button(action: { Task { await appState.syncQRZ(context: modelContext) } }) {
                    Label("Sync QRZ", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(action: { Task { await appState.syncLoTW(context: modelContext) } }) {
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
    }
}
