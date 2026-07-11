import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Formats offered by the unified export sheet.
enum ExportFormat: String, CaseIterable, Identifiable {
    case adif
    case lotw
    case pota

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .adif: return String(localized: "ADIF")
        case .lotw: return String(localized: "LoTW")
        case .pota: return String(localized: "POTA")
        }
    }
}

/// One export flow for every format: standard ADIF (full log or the current
/// filter), the not-yet-uploaded slice in the form LoTW's TQSL signer
/// expects, and a POTA activation log.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    let allQSOs: [QSO]

    @State private var format: ExportFormat = .adif
    @State private var useFilteredScope = true

    // LoTW: QSOs with `lotwQslSent != "Y"`, i.e. never seen in a LoTW report.
    @State private var unuploadedCount = 0
    #if os(macOS)
    /// nil when TQSL isn't installed — the LoTW section then only exports.
    @State private var tqslURL: URL?
    /// True after TQSL was launched; explains the follow-up download sync.
    @State private var tqslLaunched = false
    #endif

    // POTA
    @State private var parkReference = ""
    @State private var activationDate = Date()
    @State private var potaQSOs: [QSO] = []

    #if os(macOS)
    @State private var showADIFExporter = false
    @State private var adifDocument: ADIFDocument?
    @State private var showPOTAExporter = false
    @State private var potaDocument = POTADocument(content: "")
    @State private var exportFilename = "log.adi"
    #else
    @State private var shareFile: ShareFile?
    #endif

    private let tqslDownloadURL = URL(string: "https://www.arrl.org/tqsl-download")!

    private var activeQSOs: [QSO] {
        allQSOs.filter { $0.deletedAt == nil }
    }

    private var filteredQSOs: [QSO] {
        appState.filteredQSOs(from: allQSOs)
    }

    private var hasActiveFilter: Bool {
        appState.hasActiveFilters || !appState.searchText.isEmpty
    }

    private var adifQSOs: [QSO] {
        hasActiveFilter && useFilteredScope ? filteredQSOs : activeQSOs
    }

    private var potaDateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: activationDate)
    }

    private var exportDisabled: Bool {
        switch format {
        case .adif: return adifQSOs.isEmpty
        case .lotw: return unuploadedCount == 0
        case .pota: return parkReference.isEmpty || potaQSOs.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { f in
                            Text(f.localizedName).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch format {
                case .adif: adifSection
                case .lotw: lotwSection
                case .pota: potaSection
                }
            }
            .navigationTitle("Export")
            #if os(macOS)
            .formStyle(.grouped)
            .frame(width: 460, height: 440)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { beginExport() }
                        .disabled(exportDisabled)
                }
            }
            .onAppear(perform: refresh)
            .onChange(of: activationDate) { _, _ in refreshPOTAQSOs() }
            .onChange(of: parkReference) { _, _ in refreshPOTAQSOs() }
            #if os(macOS)
            .fileExporter(isPresented: $showADIFExporter,
                          document: adifDocument,
                          contentType: ADIFDocument.adifType,
                          defaultFilename: exportFilename) { result in
                if case .success(let url) = result {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .fileExporter(isPresented: $showPOTAExporter,
                          document: potaDocument,
                          contentType: ADIFDocument.adifType,
                          defaultFilename: exportFilename) { result in
                if case .success = result { dismiss() }
            }
            #else
            .sheet(item: $shareFile) { file in
                ShareSheet(items: [file.url])
                    .presentationDetents([.medium, .large])
            }
            #endif
        }
    }

    // MARK: - ADIF

    @ViewBuilder
    private var adifSection: some View {
        Section {
            if hasActiveFilter {
                Picker("QSOs", selection: $useFilteredScope) {
                    Text("Current Filter (\(filteredQSOs.count))").tag(true)
                    Text("Entire Log (\(activeQSOs.count))").tag(false)
                }
                .pickerStyle(.segmented)
            } else {
                HStack {
                    Text("QSOs to export")
                    Spacer()
                    Text("\(activeQSOs.count)").bold()
                }
            }
        } footer: {
            Text("Standard ADIF file, readable by every logging program and upload service.")
        }
    }

    // MARK: - LoTW

    @ViewBuilder
    private var lotwSection: some View {
        Section {
            HStack {
                Text("QSOs not yet uploaded")
                Spacer()
                Text("\(unuploadedCount)").bold()
            }

            #if os(macOS)
            if tqslURL != nil {
                Button {
                    Task {
                        if await appState.uploadViaTQSL(context: modelContext) {
                            tqslLaunched = true
                        }
                    }
                } label: {
                    Label("Sign & Upload with TQSL", systemImage: "square.and.arrow.up")
                }
                .disabled(appState.isSyncing || unuploadedCount == 0)

                if tqslLaunched {
                    Text("TQSL is signing and uploading your log. When it finishes, run the LoTW sync so the upload status updates here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Link(destination: tqslDownloadURL) {
                    Label("Get TQSL from ARRL", systemImage: "arrow.down.circle")
                }
            }
            #else
            Link(destination: tqslDownloadURL) {
                Label("Get TQSL from ARRL", systemImage: "arrow.down.circle")
            }
            #endif
        } footer: {
            Text("LoTW only accepts digitally signed logs. Export the QSOs that have not been uploaded, sign and upload the file with TQSL, then sync LoTW to update their status.")
        }
    }

    // MARK: - POTA

    @ViewBuilder
    private var potaSection: some View {
        Section {
            HStack {
                Text("Park")
                TextField("US-0001", text: $parkReference)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .onChange(of: parkReference) { _, v in
                        parkReference = v.uppercased()
                    }
            }

            DatePicker("Date", selection: $activationDate, displayedComponents: .date)

            HStack {
                Text("QSOs on this date")
                Spacer()
                Text("\(potaQSOs.count)")
                    .foregroundStyle(potaQSOs.isEmpty ? .red : .primary)
                    .bold()
            }
        } footer: {
            Text("Activation log with the park reference stamped on every QSO. Upload the exported file at pota.app.")
        }
    }

    // MARK: - Actions

    private func refresh() {
        #if os(macOS)
        tqslURL = TQSLLauncher.locate()
        #endif
        refreshUnuploadedCount()
        refreshPOTAQSOs()
    }

    private func refreshUnuploadedCount() {
        // NULL never matches `!= "Y"` in the SQLite store, so nil is
        // checked explicitly.
        let descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.lotwQslSent == nil || $0.lotwQslSent != "Y" })
        unuploadedCount = (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func refreshPOTAQSOs() {
        potaQSOs = POTAExportBuilder.matchingQSOs(
            context: modelContext, dateString: potaDateString, park: parkReference)
    }

    private func beginExport() {
        switch format {
        case .adif: exportADIF()
        case .lotw: exportLoTW()
        case .pota: exportPOTA()
        }
    }

    private func exportADIF() {
        let name = ADIFDocument.exportFileName(
            callsign: appState.settings?.stationCallsign, suffix: "log")
        #if os(macOS)
        exportFilename = name
        adifDocument = ADIFDocument(qsos: adifQSOs)
        showADIFExporter = true
        #else
        shareText(ADIFWriter().write(qsos: adifQSOs), filename: name)
        #endif
    }

    private func exportLoTW() {
        Task {
            do {
                let records = try await appState.lotwUploadRecords(context: modelContext)
                guard !records.isEmpty else { return }
                let name = ADIFDocument.exportFileName(
                    callsign: appState.settings?.stationCallsign, suffix: "lotw")
                #if os(macOS)
                exportFilename = name
                adifDocument = ADIFDocument(records: records)
                showADIFExporter = true
                #else
                shareText(ADIFWriter().write(records: records), filename: name)
                #endif
            } catch {
                appState.errorMessage = String(
                    localized: "Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func exportPOTA() {
        let callsign = appState.settings?.stationCallsign ?? ""
        let content = POTAExportBuilder.buildContent(
            qsos: potaQSOs, park: parkReference, callsign: callsign)
        let name = POTAExportBuilder.filename(
            callsign: callsign, park: parkReference, dateString: potaDateString)
        #if os(macOS)
        exportFilename = name
        potaDocument = POTADocument(content: content)
        showPOTAExporter = true
        #else
        shareText(content, filename: name)
        #endif
    }

    #if os(iOS)
    private func shareText(_ content: String, filename: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            shareFile = ShareFile(url: url)
        } catch {
            appState.errorMessage = String(
                localized: "Export failed: \(error.localizedDescription)")
        }
    }
    #endif
}
