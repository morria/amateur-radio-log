import Foundation

final class ADIFWriter {
    func write(qsos: [QSO], stationCallsign: String? = nil) -> String {
        write(records: qsos.map(QSORecord.init), stationCallsign: stationCallsign)
    }

    func write(records: [QSORecord], stationCallsign: String? = nil) -> String {
        var output = ""

        // Header
        output += "ADIF Export from Amateur Radio Log\n"
        output += "\(adifField("ADIF_VER", "3.1.4"))"
        output += "\(adifField("PROGRAMID", "AmateurRadioLog"))"
        output += "\(adifField("PROGRAMVERSION", "1.0.0"))"
        output += "\(adifField("CREATED_TIMESTAMP", ADIFDateFormatter.dateString(from: Date()) + " " + ADIFDateFormatter.timeString(from: Date())))"
        output += "\n<EOH>\n\n"

        // Records
        for record in records {
            output += writeRecord(record)
            output += "\n"
        }

        return output
    }

    func writeToURL(_ url: URL, qsos: [QSO]) throws {
        let content = write(qsos: qsos)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write a single QSO record without ADIF file header (for API uploads)
    func writeSingleRecord(_ q: QSO) -> String {
        writeRecord(QSORecord(from: q))
    }

    /// Write a single record without ADIF file header (for API uploads).
    ///
    /// `omitting` drops named fields from the output. Wavelog uses it for the
    /// station-location fields: it takes those from the station profile a QSO
    /// is filed under, and *rejects* any record whose `MY_GRIDSQUARE`
    /// disagrees with that profile ("Differing locator ... : SKIPPED").
    func writeSingleRecord(_ r: QSORecord, omitting: Set<String> = []) -> String {
        writeRecord(r, omitting: omitting)
    }

    // MARK: - Private

    private func writeRecord(_ q: QSORecord, omitting: Set<String> = []) -> String {
        var fields = ""
        func adifField(_ name: String, _ value: String) -> String {
            omitting.contains(name) ? "" : self.adifField(name, value)
        }
        func optField(_ name: String, _ value: String?) -> String {
            omitting.contains(name) ? "" : self.optField(name, value)
        }

        fields += adifField("CALL", q.call)
        fields += adifField("QSO_DATE", q.qsoDate)
        fields += adifField("TIME_ON", q.timeOn)
        fields += optField("TIME_OFF", q.timeOff)
        fields += freqField("FREQ", q.freq)
        fields += freqField("FREQ_RX", q.freqRx)
        fields += optField("BAND", q.bandRaw)
        fields += optField("BAND_RX", q.bandRxRaw)
        fields += optField("MODE", q.modeRaw)
        fields += optField("SUBMODE", q.submode)
        fields += optField("RST_SENT", q.rstSent)
        fields += optField("RST_RCVD", q.rstRcvd)
        fields += optField("NAME", q.name)
        fields += optField("QTH", q.qth)
        fields += optField("GRIDSQUARE", q.gridsquare)
        fields += optField("COUNTRY", q.country)
        fields += optField("DXCC", q.dxcc.map { String($0) })
        fields += optField("STATE", q.state)
        fields += optField("CNTY", q.county)
        fields += optField("CQZ", q.cqZone.map { String($0) })
        fields += optField("ITUZ", q.ituZone.map { String($0) })
        fields += optField("CONT", q.continent)
        fields += optField("IOTA", q.iota)
        fields += optField("TX_PWR", numberString(q.txPower))
        fields += optField("RX_PWR", numberString(q.rxPower))
        fields += optField("ANT_AZ", numberString(q.antAz))
        fields += optField("ANT_EL", numberString(q.antEl))
        fields += optField("QSL_SENT", q.qslSent)
        fields += optField("QSL_SENT_VIA", q.qslSentVia)
        fields += optField("QSL_RCVD", q.qslRcvd)
        fields += optField("QSL_RCVD_VIA", q.qslRcvdVia)
        fields += optField("LOTW_QSL_SENT", q.lotwQslSent)
        fields += optField("LOTW_QSL_RCVD", q.lotwQslRcvd)
        fields += optField("EQSL_QSL_SENT", q.eqslQslSent)
        fields += optField("EQSL_QSL_RCVD", q.eqslQslRcvd)
        fields += optField("STATION_CALLSIGN", q.stationCallsign)
        fields += optField("OPERATOR", q.operatorCallsign)
        fields += optField("MY_GRIDSQUARE", q.myGridsquare)
        fields += optField("MY_CITY", q.myCity)
        fields += optField("MY_STATE", q.myState)
        fields += optField("MY_COUNTRY", q.myCountry)
        fields += optField("MY_CQ_ZONE", q.myCqZone.map { String($0) })
        fields += optField("MY_ITU_ZONE", q.myItuZone.map { String($0) })
        fields += optField("SAT_NAME", q.satName)
        fields += optField("SAT_MODE", q.satMode)
        fields += optField("PROP_MODE", q.propMode)
        fields += optField("SOTA_REF", q.sotaRef)
        fields += optField("POTA_REF", q.potaRef)
        fields += optField("WWFF_REF", q.wwffRef)
        fields += optField("SIG", q.sig)
        fields += optField("SIG_INFO", q.sigInfo)
        fields += optField("MY_SIG", q.mySig)
        fields += optField("MY_SIG_INFO", q.mySigInfo)
        fields += optField("CONTEST_ID", q.contestId)
        fields += optField("SRX", q.srx.map { String($0) })
        fields += optField("STX", q.stx.map { String($0) })
        fields += optField("SRX_STRING", q.srxString)
        fields += optField("STX_STRING", q.stxString)
        fields += optField("COMMENT", q.comment)
        fields += optField("NOTES", q.notes)

        // Stable identity so re-imports of our own exports dedupe exactly
        fields += optField("APP_AMATEURRADIOLOG_UUID", q.uuid?.uuidString)

        // Extra fields
        for (key, value) in q.extraFields {
            fields += adifField(key, value)
        }

        fields += "<EOR>\n"
        return fields
    }

    private func adifField(_ name: String, _ value: String) -> String {
        // ADIF field lengths are counted in bytes (UTF-8), not characters
        "<\(name):\(value.utf8.count)>\(value) "
    }

    private func optField(_ name: String, _ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "" }
        return adifField(name, value)
    }

    /// FREQ/FREQ_RX in MHz. Six decimals is 1 Hz — finer than any radio
    /// reports — and a non-positive frequency is never a real dial reading,
    /// so it is dropped rather than exported: BAND still carries the QSO,
    /// where a bogus FREQ would cost the whole record at upload time.
    private func freqField(_ name: String, _ mhz: Double?) -> String {
        guard let mhz, mhz > 0, let text = numberString(mhz, decimals: 6) else { return "" }
        return adifField(name, text)
    }

    /// ADIF numbers must be plain decimals. `String(Double)` is a debug
    /// description rather than a formatter: it prints the binary artifacts a
    /// value picks up from unit conversion or another logger's export
    /// ("21.073999999999998"), falls back to scientific notation at the
    /// extremes ("1e-05"), and renders "nan"/"inf" verbatim. Strict
    /// consumers — QRZ's logbook API among them — reject the whole record
    /// over any of the three. Fixed decimals with the trailing zeros trimmed
    /// keep every digit a QSO can legitimately carry.
    private func numberString(_ value: Double?, decimals: Int = 3) -> String? {
        guard let value, value.isFinite else { return nil }
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
