import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Operation List

/// Every operation ever run — solo POTA/SOTA/general sessions and shared
/// multi-operator ones — newest first. Tap through for the log, export,
/// upload and editing.
struct OperationListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Operation.createdAt, order: .reverse) private var operations: [Operation]

    @State private var pendingDelete: Operation?

    var body: some View {
        NavigationStack {
            Group {
                if operations.isEmpty {
                    ContentUnavailableView {
                        Label("No Operations", systemImage: "folder")
                    } description: {
                        Text("Operations you start — POTA or SOTA activations, general sessions, shared multi-operator logs — appear here with their QSOs.")
                    }
                } else {
                    List(operations, id: \.persistentModelID) { operation in
                        NavigationLink {
                            OperationDetailView(operation: operation,
                                                onNavigateAway: { dismiss() })
                        } label: {
                            OperationRow(operation: operation,
                                         isActive: isActive(operation))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = operation
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Operations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 480)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .operationDeleteDialog(pendingDelete: $pendingDelete)
        }
    }

    private func isActive(_ operation: Operation) -> Bool {
        guard let uuid = operation.uuid else { return false }
        return appState.activationSession?.operationId == uuid
            || appState.activeOperation?.id == uuid
    }
}

// MARK: - Delete Dialog

/// Shared keep-or-delete confirmation: deleting an operation always asks
/// what happens to its QSOs.
private struct OperationDeleteDialog: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Binding var pendingDelete: Operation?
    /// Runs after a confirmed delete (pop the detail screen).
    var onDeleted: (() -> Void)?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete \(pendingDelete?.displayTitle ?? "")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { operation in
            let count = qsoCount(operation)
            if count > 0 {
                Button("Delete Operation & \(count) QSOs", role: .destructive) {
                    delete(operation, deleteQSOs: true)
                }
                Button("Delete Operation, Keep QSOs") {
                    delete(operation, deleteQSOs: false)
                }
            } else {
                Button("Delete Operation", role: .destructive) {
                    delete(operation, deleteQSOs: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { operation in
            if qsoCount(operation) > 0 {
                Text("Keeping the QSOs leaves them in your log without the operation tag. Deleting them removes them from the log on all your devices.")
            } else {
                Text("This operation has no QSOs.")
            }
        }
    }

    private func qsoCount(_ operation: Operation) -> Int {
        guard let uuid = operation.uuid else { return 0 }
        let target: UUID? = uuid
        let descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.operationId == target && $0.deletedAt == nil })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func delete(_ operation: Operation, deleteQSOs: Bool) {
        pendingDelete = nil
        // Dismiss the screen showing the model BEFORE deleting it: a detail
        // view re-rendering its @Bindable during the pop would touch a
        // deleted SwiftData model (crashes on device).
        onDeleted?()
        let appState = appState
        let context = modelContext
        Task { @MainActor in
            // One runloop turn so the pop is committed first.
            appState.deleteOperation(operation, deleteQSOs: deleteQSOs, context: context)
        }
    }
}

extension View {
    fileprivate func operationDeleteDialog(pendingDelete: Binding<Operation?>,
                                           onDeleted: (() -> Void)? = nil) -> some View {
        modifier(OperationDeleteDialog(pendingDelete: pendingDelete, onDeleted: onDeleted))
    }
}

// MARK: - Row

private struct OperationRow: View {
    let operation: Operation
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: operation.kind?.icon ?? "person.3")
                .foregroundStyle(isActive ? .green : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(operation.displayTitle)
                        .font(.body.weight(.medium))
                    if isActive {
                        Text("ON AIR")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                HStack(spacing: 6) {
                    Text(operation.kind?.localizedName ?? String(localized: "Shared"))
                    if let name = operation.referenceName, !name.isEmpty {
                        Text("·")
                        Text(name).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let started = operation.startedAt {
                Text(started, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

/// One operation: its stats, QSOs, export/upload and editable metadata.
struct OperationDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var operation: Operation
    /// Closes the enclosing Operations sheet when an action navigates the
    /// app elsewhere (dismiss() here would only pop back to the list).
    var onNavigateAway: (() -> Void)?

    @State private var qsoCount = 0
    @State private var pendingDelete: Operation?
    #if os(macOS)
    @State private var showExporter = false
    @State private var exportDocument = POTADocument(content: "")
    @State private var exportFilename = "operation.adi"
    #else
    @State private var shareFile: ShareFile?
    #endif

    private var isActive: Bool {
        guard let uuid = operation.uuid else { return false }
        return appState.activationSession?.operationId == uuid
            || appState.activeOperation?.id == uuid
    }

    private var referenceLabel: LocalizedStringKey {
        switch operation.kind {
        case .pota: return "Park"
        case .sota: return "Summit"
        default: return "Reference"
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(operation.kind?.localizedName ?? String(localized: "Shared"),
                          systemImage: operation.kind?.icon ?? "person.3")
                    Spacer()
                    if isActive {
                        Text("ON AIR")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                }
                HStack {
                    Text("QSOs")
                    Spacer()
                    Text("\(qsoCount)").bold()
                }
                if let started = operation.startedAt {
                    HStack {
                        Text("Started")
                        Spacer()
                        Text(started, format: .dateTime.month().day().year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                if let ended = operation.endedAt {
                    HStack {
                        Text("Ended")
                        Spacer()
                        Text(ended, format: .dateTime.month().day().year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    appState.showLogFiltered(operationId: operation.uuid,
                                             operationLabel: operation.displayTitle)
                    appState.revealDetailColumn()
                    onNavigateAway?()
                } label: {
                    Label("Show QSOs in Log", systemImage: "list.bullet.rectangle")
                }
                .disabled(qsoCount == 0)

                Button(action: exportLog) {
                    Label(operation.kind == .pota
                          ? "Export Log (POTA ADIF)…"
                          : "Export Log (ADIF)…",
                          systemImage: "square.and.arrow.up")
                }
                .disabled(qsoCount == 0)

                if let uploadURL = operation.kind?.uploadURL {
                    Link(destination: uploadURL) {
                        Label(operation.kind == .pota
                              ? "Upload at pota.app"
                              : "Upload to the SOTA Database",
                              systemImage: "arrow.up.circle")
                    }
                }
            } footer: {
                if operation.kind == .pota {
                    Text("Export writes an ADIF file with your park stamped on every QSO, then upload it on the POTA website.")
                } else if operation.kind == .sota {
                    Text("Export writes an ADIF file with your summit stamped on every QSO, then upload it on the SOTA database site.")
                }
            }

            Section("Edit") {
                HStack {
                    Text("Name")
                    TextField("Operation name", text: $operation.name)
                        .multilineTextAlignment(.trailing)
                }
                if operation.kind == .pota || operation.kind == .sota {
                    HStack {
                        Text(referenceLabel)
                        TextField("US-0001", text: Binding(
                            get: { operation.reference ?? "" },
                            set: { operation.reference = $0.isEmpty ? nil : $0.uppercased() }
                        ))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                    }
                }
            }

            if isActive, appState.activationSession?.operationId == operation.uuid {
                Section {
                    Button(role: .destructive) {
                        appState.endActivation(context: modelContext)
                    } label: {
                        Text("End Operation")
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    pendingDelete = operation
                } label: {
                    Label("Delete Operation…", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("You choose whether the operation's QSOs stay in your log or are deleted with it.")
            }
        }
        .operationDeleteDialog(pendingDelete: $pendingDelete, onDeleted: { dismiss() })
        .navigationTitle(operation.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .onAppear(perform: refreshCount)
        #if os(macOS)
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: ADIFDocument.adifType,
                      defaultFilename: exportFilename) { result in
            if case .success(let url) = result {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        #else
        .sheet(item: $shareFile) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    // MARK: Data

    private func operationQSOs() -> [QSO] {
        guard let uuid = operation.uuid else { return [] }
        let target: UUID? = uuid
        let descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.operationId == target && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\QSO.qsoDate), SortDescriptor(\QSO.timeOn)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func refreshCount() {
        guard let uuid = operation.uuid else { return }
        let target: UUID? = uuid
        let descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.operationId == target && $0.deletedAt == nil })
        qsoCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// POTA operations export through the POTA builder (park injected on
    /// every record, CRLF line endings); everything else is standard ADIF.
    private func exportLog() {
        let qsos = operationQSOs()
        guard !qsos.isEmpty else { return }
        let callsign = appState.settings?.stationCallsign ?? ""

        let content: String
        let filename: String
        if operation.kind == .pota, let park = operation.reference, !park.isEmpty {
            content = POTAExportBuilder.buildContent(qsos: qsos, park: park, callsign: callsign)
            let dateString = (operation.startedAt ?? Date())
                .formatted(.iso8601.year().month().day().dateSeparator(.omitted))
            filename = POTAExportBuilder.filename(
                callsign: callsign, park: park, dateString: dateString)
        } else {
            content = ADIFWriter().write(qsos: qsos)
            let suffix = operation.displayTitle
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()
            filename = ADIFDocument.exportFileName(
                callsign: callsign, suffix: suffix,
                date: operation.startedAt ?? Date())
        }

        #if os(macOS)
        exportFilename = filename
        exportDocument = POTADocument(content: content)
        showExporter = true
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            shareFile = ShareFile(url: url)
        } catch {
            appState.errorMessage = String(
                localized: "Export failed: \(error.localizedDescription)")
        }
        #endif
    }
}
