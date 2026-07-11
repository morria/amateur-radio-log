import SwiftUI
import SwiftData

@main
struct AmateurRadioLogApp: App {
    @State private var appState = AppState()

    let container: ModelContainer = {
        let schema = Schema([QSO.self, AppSettings.self, Operation.self, ReplicationEntry.self])
        let config = ModelConfiguration(
            "AmateurRadioLog",
            schema: schema,
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        // Idempotent identity backfill (assign missing uuids, repair
        // duplicates) on a background context at every launch
        QSOIdentityBackfill.run(container: container)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onOpenURL { url in
                    appState.pendingImportURL = url
                }
        }
        .modelContainer(container)
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New QSO") {
                    NotificationCenter.default.post(name: .newQSO, object: nil)
                }
                .keyboardShortcut("n")

                Divider()

                Button("Import ADIF...") {
                    NotificationCenter.default.post(name: .importADIF, object: nil)
                }
                .keyboardShortcut("i")

                Button("Export...") {
                    NotificationCenter.default.post(name: .exportADIF, object: nil)
                }
                .keyboardShortcut("e")
            }

            CommandGroup(after: .textEditing) {
                Button("Find QSO") {
                    appState.selectedTab = .log
                    // Post async so the log tab (and its search field) is
                    // mounted before the focus request arrives
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .findQSO, object: nil)
                    }
                }
                .keyboardShortcut("f")

                Button("Quick Entry") {
                    // The New QSO tab focuses its callsign field on appear.
                    appState.selectedTab = .entry
                }
                .keyboardShortcut("l")
            }

            CommandGroup(after: .sidebar) {
                Button("Show Selected on Map") {
                    NotificationCenter.default.post(name: .showQSOOnMap, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
        }
        .modelContainer(container)
        #endif
    }
}

extension Notification.Name {
    static let newQSO = Notification.Name("newQSO")
    static let importADIF = Notification.Name("importADIF")
    static let exportADIF = Notification.Name("exportADIF")
    static let findQSO = Notification.Name("findQSO")
}
