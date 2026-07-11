import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct POTAExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allSettings: [AppSettings]

    @State private var parkReference = ""
    @State private var activationDate = Date()
    @State private var showExporter = false
    @State private var exportContent = ""
    @State private var exportFilename = "pota.adi"
    @State private var matchingQSOs: [QSO] = []

    /// Standalone export: empty park, today's date. "End Activation" passes
    /// the session's park and start date to prefill the sheet.
    init(prefillPark: String = "", prefillDate: Date = Date()) {
        _parkReference = State(initialValue: prefillPark.uppercased())
        _activationDate = State(initialValue: prefillDate)
    }

    private var stationCallsign: String {
        allSettings.first?.stationCallsign ?? ""
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: activationDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Activation Details") {
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
                }

                Section {
                    HStack {
                        Text("QSOs on this date")
                        Spacer()
                        Text("\(matchingQSOs.count)")
                            .foregroundStyle(matchingQSOs.isEmpty ? .red : .primary)
                            .bold()
                    }

                    if matchingQSOs.isEmpty {
                        Text("No QSOs found for this date.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matchingQSOs.prefix(5), id: \.persistentModelID) { qso in
                            HStack {
                                Text(qso.call).font(.callout.monospaced())
                                Spacer()
                                if let band = qso.band {
                                    Text(band.displayName).font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.blue.opacity(0.15)).clipShape(Capsule())
                                }
                                if let mode = qso.mode {
                                    Text(mode.displayName).font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.green.opacity(0.15)).clipShape(Capsule())
                                }
                            }
                        }
                        if matchingQSOs.count > 5 {
                            Text("+ \(matchingQSOs.count - 5) more")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Upload the exported file at pota.app.")
                }
            }
            .navigationTitle("POTA Export")
            #if os(macOS)
            .formStyle(.grouped)
            .frame(width: 500, height: 400)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { prepareExport() }
                        .disabled(parkReference.isEmpty || matchingQSOs.isEmpty)
                }
            }
            .onAppear(perform: refreshMatchingQSOs)
            .onChange(of: activationDate) { _, _ in
                refreshMatchingQSOs()
            }
            .onChange(of: parkReference) { _, _ in
                refreshMatchingQSOs()
            }
            .fileExporter(
                isPresented: $showExporter,
                document: POTADocument(content: exportContent),
                contentType: ADIFDocument.adifType,
                defaultFilename: exportFilename
            ) { result in
                if case .success = result {
                    dismiss()
                }
            }
        }
    }

    private func refreshMatchingQSOs() {
        matchingQSOs = POTAExportBuilder.matchingQSOs(
            context: modelContext, dateString: dateString, park: parkReference)
    }

    private func prepareExport() {
        exportContent = POTAExportBuilder.buildContent(
            qsos: matchingQSOs, park: parkReference, callsign: stationCallsign)
        exportFilename = POTAExportBuilder.filename(
            callsign: stationCallsign, park: parkReference, dateString: dateString)
        showExporter = true
    }
}

/// POTA export logic shared by POTAExportSheet (activation flow) and the
/// unified ExportSheet.
@MainActor
enum POTAExportBuilder {
    /// QSOs on the activation date. When a park is set, QSOs explicitly
    /// stamped for a *different* park (a second activation the same day)
    /// are excluded; unstamped QSOs stay in and get the park injected at
    /// export time.
    static func matchingQSOs(context: ModelContext, dateString: String, park: String) -> [QSO] {
        let descriptor = FetchDescriptor<QSO>(
            predicate: #Predicate { $0.qsoDate == dateString },
            sortBy: [SortDescriptor(\.timeOn)]
        )
        var qsos = (try? context.fetch(descriptor)) ?? []
        let trimmedPark = park.trimmingCharacters(in: .whitespaces)
        if !trimmedPark.isEmpty {
            qsos = qsos.filter { qso in
                guard let info = qso.mySigInfo, !info.isEmpty else { return true }
                return info.caseInsensitiveCompare(trimmedPark) == .orderedSame
            }
        }
        return qsos
    }

    static func buildContent(qsos: [QSO], park: String, callsign: String) -> String {
        let writer = ADIFWriter()

        var output = ""
        output += "ADIF Export from Amateur Radio Log - POTA Activation\r\n"
        output += "<ADIF_VER:5>3.1.4 "
        output += "<PROGRAMID:15>AmateurRadioLog "
        output += "<PROGRAMVERSION:5>1.0.0 "
        output += "\r\n<EOH>\r\n\r\n"

        for qso in qsos {
            var record = QSORecord(from: qso)
            // Hoist legacy MY_SIG/MY_SIG_INFO stored as overflow fields
            // (imports predating the dedicated columns) so they aren't
            // written twice.
            if let legacy = record.extraFields.removeValue(forKey: "MY_SIG"),
               (record.mySig ?? "").isEmpty {
                record.mySig = legacy
            }
            if let legacy = record.extraFields.removeValue(forKey: "MY_SIG_INFO"),
               (record.mySigInfo ?? "").isEmpty {
                record.mySigInfo = legacy
            }
            // Ensure POTA fields are present
            if (record.mySig ?? "").isEmpty { record.mySig = "POTA" }
            if (record.mySigInfo ?? "").isEmpty { record.mySigInfo = park }
            if (record.stationCallsign ?? "").isEmpty && !callsign.isEmpty {
                record.stationCallsign = callsign
            }
            // Use CRLF line endings per POTA requirements
            output += writer.writeSingleRecord(record)
                .replacingOccurrences(of: "\n", with: "\r\n")
            output += "\r\n"
        }
        return output
    }

    /// Filename convention: callsign@park-date.adi
    static func filename(callsign: String, park: String, dateString: String) -> String {
        let safePark = park.replacingOccurrences(of: "/", with: "-")
        return "\(callsign.isEmpty ? "log" : callsign)@\(safePark)-\(dateString).adi"
    }
}

struct POTADocument: FileDocument {
    static var readableContentTypes: [UTType] { [ADIFDocument.adifType] }
    static var writableContentTypes: [UTType] { [ADIFDocument.adifType] }

    let content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        content = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    }
}
