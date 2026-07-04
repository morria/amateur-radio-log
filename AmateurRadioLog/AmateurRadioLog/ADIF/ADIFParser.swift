import Foundation

struct ADIFRecord {
    var fields: [String: String] = [:]
}

struct ADIFFile {
    var header: [String: String]
    var records: [ADIFRecord]
}

enum ADIFParserError: Error, LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "ADIF parse error: \(msg)"
        }
    }
}

final class ADIFParser {
    func parse(string: String) throws -> ADIFFile {
        var header: [String: String] = [:]
        var records: [ADIFRecord] = []

        let content = string
        var index = content.startIndex

        // Parse header (everything before <EOH>)
        if let eohRange = content.range(of: "<EOH>", options: .caseInsensitive) {
            let headerStr = String(content[content.startIndex..<eohRange.lowerBound])
            header = parseFields(headerStr)
            index = eohRange.upperBound
        } else if let firstTag = content.range(of: "<", options: []) {
            // No header; check if first tag looks like a record field
            let beforeTag = content[content.startIndex..<firstTag.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !beforeTag.isEmpty {
                // Has preamble text but no <EOH> — skip to first tag
                index = firstTag.lowerBound
            }
        }

        // Parse records
        let recordChunks = splitOnEOR(content[index...])

        for chunk in recordChunks {
            // Trimming tolerates over-declared lengths on a record's last
            // field (each chunk is copied once — still O(n) overall).
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let fields = parseFields(trimmed)
            if !fields.isEmpty {
                records.append(ADIFRecord(fields: fields))
            }
        }

        return ADIFFile(header: header, records: records)
    }

    func parse(url: URL) throws -> ADIFFile {
        let data = try Data(contentsOf: url)
        guard let string = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            throw ADIFParserError.invalidFormat("Unable to decode file as text")
        }
        return try parse(string: string)
    }

    func recordsToQSOs(_ records: [ADIFRecord]) -> [QSO] {
        records.compactMap { recordToQSORecord($0)?.makeQSO() }
    }

    /// Sendable DTO variant used by service actors and the background store.
    func recordsToQSORecords(_ records: [ADIFRecord]) -> [QSORecord] {
        records.compactMap { recordToQSORecord($0) }
    }

    // MARK: - Private

    /// Single forward scan: finds each <EOR> case-insensitively from the
    /// current index and slices — never re-materializes the remainder, so a
    /// file with n records is O(n) instead of O(n²) tail copies.
    private func splitOnEOR(_ str: Substring) -> [Substring] {
        var chunks: [Substring] = []
        var index = str.startIndex
        while index < str.endIndex,
              let range = str.range(of: "<EOR>", options: .caseInsensitive,
                                    range: index..<str.endIndex) {
            chunks.append(str[index..<range.lowerBound])
            index = range.upperBound
        }
        // Anything left after the last <EOR>
        if index < str.endIndex {
            let leftover = str[index...]
            if leftover.contains("<") {
                chunks.append(leftover)
            }
        }
        return chunks
    }

    private func parseFields(_ str: String) -> [String: String] {
        var fields: [String: String] = [:]
        var i = str.startIndex

        while i < str.endIndex {
            // Find next '<'
            guard let tagStart = str[i...].firstIndex(of: "<") else { break }
            guard let tagEnd = str[tagStart...].firstIndex(of: ">") else { break }

            let tagContent = String(str[str.index(after: tagStart)..<tagEnd])
            let parts = tagContent.split(separator: ":", maxSplits: 2)

            guard let fieldName = parts.first else {
                i = str.index(after: tagEnd)
                continue
            }

            let name = String(fieldName).uppercased()

            // Skip special tags
            if name == "EOH" || name == "EOR" {
                i = str.index(after: tagEnd)
                continue
            }

            if parts.count >= 2, let length = Int(parts[1]) {
                let dataStart = str.index(after: tagEnd)
                // ADIF field lengths are counted in bytes (UTF-8), not characters
                let utf8 = str.utf8
                let bytesRemaining = utf8.distance(from: dataStart, to: utf8.endIndex)
                var utf8End = utf8.index(dataStart, offsetBy: min(length, bytesRemaining))
                var dataEnd = utf8End.samePosition(in: str)
                // If the length lands mid-scalar/mid-character (e.g. a legacy
                // char-counted file), round forward to the next boundary.
                while dataEnd == nil && utf8End < utf8.endIndex {
                    utf8.formIndex(after: &utf8End)
                    dataEnd = utf8End.samePosition(in: str)
                }
                let end = dataEnd ?? str.endIndex
                let value = String(str[dataStart..<end])
                fields[name] = value
                i = end
            } else {
                i = str.index(after: tagEnd)
            }
        }

        return fields
    }

    private func recordToQSORecord(_ record: ADIFRecord) -> QSORecord? {
        let f = record.fields
        guard let call = f["CALL"], !call.isEmpty,
              let date = f["QSO_DATE"],
              let time = f["TIME_ON"] else {
            return nil
        }

        var qso = QSORecord(call: call.uppercased(), qsoDate: date, timeOn: time)
        qso.timeOff = f["TIME_OFF"]
        qso.freq = f["FREQ"].flatMap { Double($0) }
        qso.freqRx = f["FREQ_RX"].flatMap { Double($0) }
        qso.bandRaw = (f["BAND"].flatMap { Band(rawValue: $0.lowercased()) }
            ?? qso.freq.flatMap { Band.from(frequencyMHz: $0) })?.rawValue
        qso.bandRxRaw = f["BAND_RX"].flatMap { Band(rawValue: $0.lowercased()) }?.rawValue
        qso.modeRaw = f["MODE"].flatMap { Mode(rawValue: $0.uppercased()) }?.rawValue
        qso.submode = f["SUBMODE"]
        qso.rstSent = f["RST_SENT"]
        qso.rstRcvd = f["RST_RCVD"]
        qso.name = f["NAME"]
        qso.qth = f["QTH"]
        qso.gridsquare = f["GRIDSQUARE"]
        qso.country = f["COUNTRY"]
        qso.dxcc = f["DXCC"].flatMap { Int($0) }
        qso.state = f["STATE"]
        qso.county = f["CNTY"]
        qso.cqZone = f["CQZ"].flatMap { Int($0) }
        qso.ituZone = f["ITUZ"].flatMap { Int($0) }
        qso.continent = f["CONT"]
        qso.iota = f["IOTA"]
        qso.txPower = f["TX_PWR"].flatMap { Double($0) }
        qso.rxPower = f["RX_PWR"].flatMap { Double($0) }
        qso.antAz = f["ANT_AZ"].flatMap { Double($0) }
        qso.antEl = f["ANT_EL"].flatMap { Double($0) }
        qso.qslSent = f["QSL_SENT"]
        qso.qslSentVia = f["QSL_SENT_VIA"]
        qso.qslRcvd = f["QSL_RCVD"]
        qso.qslRcvdVia = f["QSL_RCVD_VIA"]
        qso.lotwQslSent = f["LOTW_QSL_SENT"]
        qso.lotwQslRcvd = f["LOTW_QSL_RCVD"]
        qso.eqslQslSent = f["EQSL_QSL_SENT"]
        qso.eqslQslRcvd = f["EQSL_QSL_RCVD"]
        qso.stationCallsign = f["STATION_CALLSIGN"]
        qso.operatorCallsign = f["OPERATOR"]
        // Stable identity written by this app's exporter; restoring it lets
        // re-imports of our own exports dedupe exactly (QSOMatcher tier 1).
        if let uuid = f["APP_AMATEURRADIOLOG_UUID"].flatMap({ UUID(uuidString: $0) }) {
            qso.uuid = uuid
        }
        qso.myGridsquare = f["MY_GRIDSQUARE"]
        qso.myCity = f["MY_CITY"]
        qso.myState = f["MY_STATE"]
        qso.myCountry = f["MY_COUNTRY"]
        qso.myCqZone = f["MY_CQ_ZONE"].flatMap { Int($0) }
        qso.myItuZone = f["MY_ITU_ZONE"].flatMap { Int($0) }
        qso.satName = f["SAT_NAME"]
        qso.satMode = f["SAT_MODE"]
        qso.propMode = f["PROP_MODE"]
        qso.sotaRef = f["SOTA_REF"]
        qso.potaRef = f["POTA_REF"]
        qso.wwffRef = f["WWFF_REF"]
        qso.sig = f["SIG"]
        qso.sigInfo = f["SIG_INFO"]
        qso.mySig = f["MY_SIG"]
        qso.mySigInfo = f["MY_SIG_INFO"]
        qso.contestId = f["CONTEST_ID"]
        qso.srx = f["SRX"].flatMap { Int($0) }
        qso.stx = f["STX"].flatMap { Int($0) }
        qso.srxString = f["SRX_STRING"]
        qso.stxString = f["STX_STRING"]
        qso.comment = f["COMMENT"]
        qso.notes = f["NOTES"]
        qso.latitude = f["LAT"].flatMap { parseLatLon($0) }
        qso.longitude = f["LON"].flatMap { parseLatLon($0) }

        // Compute lat/lon from grid if not set
        if qso.latitude == nil, let grid = qso.gridsquare {
            if let coord = MaidenheadConverter.toCoordinate(grid: grid) {
                qso.latitude = coord.latitude
                qso.longitude = coord.longitude
            }
        }

        // Collect extra fields not handled above
        let knownFields: Set<String> = [
            "CALL", "QSO_DATE", "TIME_ON", "TIME_OFF", "FREQ", "FREQ_RX", "BAND", "BAND_RX",
            "MODE", "SUBMODE", "RST_SENT", "RST_RCVD", "NAME", "QTH", "GRIDSQUARE",
            "COUNTRY", "DXCC", "STATE", "CNTY", "CQZ", "ITUZ", "CONT", "IOTA",
            "TX_PWR", "RX_PWR", "ANT_AZ", "ANT_EL",
            "QSL_SENT", "QSL_SENT_VIA", "QSL_RCVD", "QSL_RCVD_VIA",
            "LOTW_QSL_SENT", "LOTW_QSL_RCVD", "EQSL_QSL_SENT", "EQSL_QSL_RCVD",
            "STATION_CALLSIGN", "OPERATOR", "APP_AMATEURRADIOLOG_UUID",
            "MY_GRIDSQUARE", "MY_CITY", "MY_STATE", "MY_COUNTRY",
            "MY_CQ_ZONE", "MY_ITU_ZONE",
            "SAT_NAME", "SAT_MODE", "PROP_MODE",
            "SOTA_REF", "POTA_REF", "WWFF_REF", "SIG", "SIG_INFO",
            "MY_SIG", "MY_SIG_INFO",
            "CONTEST_ID", "SRX", "STX", "SRX_STRING", "STX_STRING",
            "COMMENT", "NOTES", "LAT", "LON"
        ]

        // Accumulate unknown fields locally and assign the dictionary once;
        // (on the QSO model, per-subscript writes JSON-round-trip the dict).
        var extras: [String: String] = [:]
        for (key, value) in f where !knownFields.contains(key) {
            extras[key] = value
        }
        qso.extraFields = extras

        return qso
    }

    private func parseLatLon(_ str: String) -> Double? {
        // ADIF lat/lon can be decimal or XDDD MM.MMM format
        if let val = Double(str) { return val }

        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }

        let direction = trimmed.last
        let numPart = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        let parts = numPart.split(separator: " ")

        guard parts.count >= 2,
              let degrees = Double(parts[0]),
              let minutes = Double(parts[1]) else { return nil }

        var value = degrees + minutes / 60.0
        if direction == "S" || direction == "W" { value = -value }
        return value
    }
}
