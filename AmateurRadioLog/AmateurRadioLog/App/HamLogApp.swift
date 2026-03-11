import SwiftUI
import SwiftData

@main
struct AmateurRadioLogApp: App {
    @State private var appState = AppState()

    var container: ModelContainer {
        let schema = Schema([QSO.self])
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
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

                Button("Export ADIF...") {
                    NotificationCenter.default.post(name: .exportADIF, object: nil)
                }
                .keyboardShortcut("e")
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
        }
        #endif
    }
}

extension Notification.Name {
    static let newQSO = Notification.Name("newQSO")
    static let importADIF = Notification.Name("importADIF")
    static let exportADIF = Notification.Name("exportADIF")
}
