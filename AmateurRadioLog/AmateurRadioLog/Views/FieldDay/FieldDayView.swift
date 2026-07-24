import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Multi-operator operation sheet: create/host an operation, browse and join
/// sessions on the local network, and — while an operation is active — show
/// the peer roster, per-operator counts, a rolling rate meter and the
/// operation's export/delete actions.
struct FieldDayView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var allQSOs: [QSO]

    @State private var newName = ""
    @State private var newContestId = ""
    @State private var showDeleteConfirm = false
    @State private var showExporter = false
    @State private var exportDocument: ADIFDocument?

    var body: some View {
        NavigationStack {
            Form {
                if let operation = appState.activeOperation {
                    activeOperationSection(operation)
                    connectionSection(operation)
                    peersSection
                    operationStatsSection(operation)
                    actionsSection(operation)
                } else {
                    createSection
                    joinSection
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(width: 480, height: 560)
            #endif
            .navigationTitle("Operation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                appState.startFieldDayBrowsing(context: modelContext)
                if newName.isEmpty {
                    newName = defaultOperationName()
                }
            }
            .onDisappear {
                // Keep browsing only while a joined session may need to
                // reconnect; otherwise stop the Bonjour browser.
                if appState.fieldDayPhase != .joined {
                    appState.stopFieldDayBrowsing()
                }
            }
            .confirmationDialog(
                "Delete this operation and all of its QSOs from your log?",
                isPresented: $showDeleteConfirm, titleVisibility: .visible
            ) {
                Button("Delete Operation", role: .destructive) {
                    guard let id = appState.activeOperation?.id ?? appState.filterOperationId
                    else { return }
                    Task { await appState.deleteFieldDayOperation(id, context: modelContext) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .fileExporter(isPresented: $showExporter,
                          document: exportDocument,
                          contentType: ADIFDocument.adifType,
                          defaultFilename: exportFilename) { _ in
                exportDocument = nil
            }
        }
    }

    // MARK: - Inactive: create / join

    private var createSection: some View {
        Section {
            TextField("Operation Name", text: $newName)
            TextField("Contest ID (optional)", text: $newContestId)
                .autocorrectionDisabled()
            Button {
                appState.startFieldDayOperation(
                    name: newName,
                    contestId: newContestId.isEmpty ? nil : newContestId,
                    context: modelContext)
            } label: {
                Label("Start Hosting", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Start an Operation")
        } footer: {
            Text("Hosts a shared log on your local network. Other operators join from this screen on their devices; every QSO anyone logs replicates to all participants.")
        }
    }

    private var joinSection: some View {
        Section("Join an Operation") {
            if appState.discoveredOperations.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for operations on your network...")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(appState.discoveredOperations) { discovered in
                Button {
                    appState.joinFieldDayOperation(discovered, context: modelContext)
                } label: {
                    HStack {
                        Label(discovered.name, systemImage: "person.3")
                        Spacer()
                        Text("Join")
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Active operation

    private func activeOperationSection(_ operation: OperationInfo) -> some View {
        Section("Active Operation") {
            LabeledContent("Name", value: operation.name)
            if let contest = operation.contestId, !contest.isEmpty {
                LabeledContent("Contest", value: contest)
            }
            if let started = operation.startedAt {
                LabeledContent("Started") {
                    Text(started, format: .relative(presentation: .named))
                }
            }
            LabeledContent("Status") {
                switch appState.fieldDayPhase {
                case .hosting:
                    Label("Hosting", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                case .joined:
                    Label("Connected", systemImage: "personalhotspot")
                        .foregroundStyle(.green)
                case .idle:
                    Label("Not Connected", systemImage: "bolt.slash")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionSection(_ operation: OperationInfo) -> some View {
        if appState.fieldDayPhase == .idle {
            Section {
                Button {
                    appState.hostFieldDayOperation(operation, context: modelContext)
                } label: {
                    Label("Resume Hosting", systemImage: "antenna.radiowaves.left.and.right")
                }
                ForEach(appState.discoveredOperations.filter { $0.operationId == operation.id }) { discovered in
                    Button {
                        appState.joinFieldDayOperation(discovered, context: modelContext)
                    } label: {
                        Label("Reconnect to \(discovered.name)", systemImage: "personalhotspot")
                    }
                }
            } footer: {
                Text("New QSOs are still tagged with this operation while disconnected; reconnecting syncs anything missed in either direction.")
            }
        }
    }

    @ViewBuilder
    private var peersSection: some View {
        if appState.fieldDayPhase != .idle {
            Section("Peers") {
                if appState.fieldDayPeers.isEmpty {
                    Text(appState.fieldDayPhase == .hosting
                         ? "Waiting for operators to join..."
                         : "Connecting...")
                        .foregroundStyle(.secondary)
                }
                ForEach(appState.fieldDayPeers) { peer in
                    HStack {
                        Circle()
                            .fill(peer.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(peerTitle(peer))
                            .font(.body.monospaced())
                        Spacer()
                        Text(peer.isConnected ? "Connected" : "Connecting...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func operationStatsSection(_ operation: OperationInfo) -> some View {
        let stats = computeStats(operation)
        return Section("Shared Log") {
            LabeledContent("Total QSOs", value: "\(stats.total)")
            LabeledContent("Rate") {
                Text("\(stats.lastHour)/hr")
                    .monospacedDigit()
                + Text(verbatim: "  ·  ")
                + Text("\(stats.lastTenMinutes) in last 10 min")
                    .font(.caption)
            }
            if stats.dupes > 0 {
                LabeledContent("Duplicates") {
                    Text("\(stats.dupes)")
                        .foregroundStyle(.red)
                }
            }
            ForEach(stats.operatorCounts, id: \.0) { op, count in
                HStack {
                    Text(op).font(.body.monospaced())
                    Spacer()
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionsSection(_ operation: OperationInfo) -> some View {
        Section {
            Button {
                appState.showLogFiltered(operationId: operation.id,
                                         operationLabel: operation.name)
                // Sheet over the sidebar: push the detail column (compact
                // width won't otherwise) and keep back-to-sidebar behavior.
                appState.revealDetailColumn()
                dismiss()
            } label: {
                Label("Show in Log", systemImage: "list.bullet.rectangle")
            }
            Button {
                exportDocument = ADIFDocument(
                    qsos: operationQSOs(operation.id).filter { $0.deletedAt == nil })
                showExporter = true
            } label: {
                Label("Export Operation (ADIF)", systemImage: "square.and.arrow.up")
            }
            Button {
                appState.endFieldDayOperation(context: modelContext)
            } label: {
                Label(appState.fieldDayPhase == .hosting
                      ? "Stop Hosting & End Operation"
                      : "Leave Operation",
                      systemImage: "xmark.circle")
            }
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete Operation & QSOs...", systemImage: "trash")
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Ending an operation keeps the shared log in your logbook (and your iCloud). Deleting removes this operation's QSOs from this device's log and its iCloud copy.")
        }
    }

    // MARK: - Helpers

    private func peerTitle(_ peer: FieldDayPeerStatus) -> String {
        if let callsign = peer.operatorCallsign, !callsign.isEmpty { return callsign }
        if let deviceId = peer.deviceId { return String(deviceId.prefix(8)) }
        return String(localized: "Unknown station")
    }

    private func operationQSOs(_ operationId: UUID) -> [QSO] {
        allQSOs.filter { $0.operationId == operationId }
    }

    private struct OperationStats {
        var total = 0
        var lastHour = 0
        var lastTenMinutes = 0
        var dupes = 0
        var operatorCounts: [(String, Int)] = []
    }

    private func computeStats(_ operation: OperationInfo) -> OperationStats {
        let qsos = operationQSOs(operation.id).filter { $0.deletedAt == nil }
        var stats = OperationStats()
        stats.total = qsos.count

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let hourKey = formatter.string(from: Date().addingTimeInterval(-3600))
        let tenMinKey = formatter.string(from: Date().addingTimeInterval(-600))

        var counts: [String: Int] = [:]
        for qso in qsos {
            counts[qso.operatorCallsign?.uppercased() ?? "?", default: 0] += 1
            let key = MapTimeRange.qsoKey(qsoDate: qso.qsoDate, timeOn: qso.timeOn)
            if key >= hourKey { stats.lastHour += 1 }
            if key >= tenMinKey { stats.lastTenMinutes += 1 }
        }
        stats.operatorCounts = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }

        stats.dupes = FieldDayDupes.dupeUUIDs(qsos.map {
            DupeProbe(uuid: $0.uuid, call: $0.call, qsoDate: $0.qsoDate,
                      timeOn: $0.timeOn, bandRaw: $0.bandRaw)
        }).count

        return stats
    }

    private var exportFilename: String {
        let name = appState.activeOperation?.name ?? "operation"
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_",
                                             options: .regularExpression)
        return "\(safe.isEmpty ? "operation" : safe).adi"
    }

    private func defaultOperationName() -> String {
        let callsign = (appState.settings?.stationCallsign ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let year = Calendar.current.component(.year, from: Date())
        if callsign.isEmpty { return String(localized: "Field Day \(String(year))") }
        return "\(callsign) Field Day \(year)"
    }
}
