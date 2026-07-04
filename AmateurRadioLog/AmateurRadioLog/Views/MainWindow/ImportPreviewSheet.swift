import SwiftUI
import SwiftData

/// Confirmation sheet shown after an ADIF file has been parsed and
/// classified against the local log, before anything is committed.
/// A pre-import snapshot of the current log is written on confirm.
struct ImportPreviewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    let preview: ImportPreview
    @State private var importDuplicates = false

    private var willImportCount: Int {
        preview.newRecords.count + (importDuplicates ? preview.duplicates.count : 0)
    }

    private var hasWork: Bool {
        willImportCount > 0 || !preview.updates.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import ADIF")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                summaryRow(
                    icon: "plus.circle.fill", color: .green,
                    text: String(localized: "\(preview.newRecords.count) new QSOs"))
                summaryRow(
                    icon: "doc.on.doc.fill", color: .secondary,
                    text: importDuplicates
                        ? String(localized: "\(preview.duplicates.count) duplicates will be imported anyway")
                        : String(localized: "\(preview.duplicates.count) duplicates will be skipped"))
                summaryRow(
                    icon: "arrow.triangle.merge", color: .blue,
                    text: String(localized: "\(preview.updates.count) existing QSOs will gain missing fields"))
                if preview.invalidCount > 0 {
                    summaryRow(
                        icon: "exclamationmark.triangle.fill", color: .orange,
                        text: String(localized: "\(preview.invalidCount) records could not be read"))
                }
            }

            if preview.updates.count > 0 {
                Text("Updates only fill in fields that are currently empty — your existing data is never overwritten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if preview.duplicates.count > 0 {
                Toggle("Import duplicates anyway", isOn: $importDuplicates)
            }

            Text("A backup of your current log is saved before importing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    appState.cancelImport()
                }
                Button(importButtonTitle) {
                    let context = modelContext
                    Task {
                        await appState.commitImport(
                            preview, importDuplicates: importDuplicates, context: context)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!hasWork)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 380)
        #endif
    }

    private var importButtonTitle: String {
        if willImportCount > 0 {
            return String(localized: "Import \(willImportCount) QSOs")
        }
        return String(localized: "Import")
    }

    private func summaryRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
        }
    }
}
