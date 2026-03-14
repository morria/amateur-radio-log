import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct POTAExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QSO.qsoDate, order: .reverse) private var allQSOs: [QSO]

    @State private var parkReference = ""
    @State private var activationDate = Date()
    @State private var showExporter = false
    @State private var exportContent = ""
    @State private var exportFilename = "pota.adi"

    private var stationCallsign: String {
        NSUbiquitousKeyValueStore.default.string(forKey: "stationCallsign") ?? ""
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: activationDate)
    }

    private var matchingQSOs: [QSO] {
        allQSOs.filter { $0.qsoDate == dateString }
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

    private func prepareExport() {
        let callsign = stationCallsign
        let park = parkReference
        let writer = ADIFWriter()

        var output = ""
        output += "ADIF Export from Amateur Radio Log - POTA Activation\r\n"
        output += "<ADIF_VER:5>3.1.4 "
        output += "<PROGRAMID:15>AmateurRadioLog "
        output += "<PROGRAMVERSION:5>1.0.0 "
        output += "\r\n<EOH>\r\n\r\n"

        for qso in matchingQSOs {
            var record = writer.writeSingleRecord(qso)
            // Ensure POTA fields are present
            if !record.contains("<MY_SIG:") {
                record = record.replacingOccurrences(of: "<EOR>", with: "<MY_SIG:4>POTA <EOR>")
            }
            if !record.contains("<MY_SIG_INFO:") {
                record = record.replacingOccurrences(of: "<EOR>", with: "<MY_SIG_INFO:\(park.count)>\(park) <EOR>")
            }
            if !record.contains("<STATION_CALLSIGN:") && !callsign.isEmpty {
                record = record.replacingOccurrences(of: "<EOR>", with: "<STATION_CALLSIGN:\(callsign.count)>\(callsign) <EOR>")
            }
            // Use CRLF line endings per POTA requirements
            output += record.replacingOccurrences(of: "\n", with: "\r\n")
            output += "\r\n"
        }

        exportContent = output
        // Filename convention: callsign@park-date.adi
        let safePark = park.replacingOccurrences(of: "/", with: "-")
        exportFilename = "\(callsign.isEmpty ? "log" : callsign)@\(safePark)-\(dateString).adi"
        showExporter = true
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
