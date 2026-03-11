import Foundation

final class ADIFWriter {
    func write(qsos: [QSO], stationCallsign: String? = nil) -> String {
        var output = ""

        // Header
        output += "ADIF Export from Amateur Radio Log\n"
        output += "\(adifField("ADIF_VER", "3.1.4"))"
        output += "\(adifField("PROGRAMID", "AmateurRadioLog"))"
        output += "\(adifField("PROGRAMVERSION", "1.0.0"))"
        output += "\(adifField("CREATED_TIMESTAMP", ADIFDateFormatter.dateString(from: Date()) + " " + ADIFDateFormatter.timeString(from: Date())))"
        output += "\n<EOH>\n\n"

        // Records
        for qso in qsos {
            output += writeRecord(qso)
            output += "\n"
        }

        return output
    }

    func writeToURL(_ url: URL, qsos: [QSO]) throws {
        let content = write(qsos: qsos)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

    private func writeRecord(_ q: QSO) -> String {
        var fields = ""

        fields += adifField("CALL", q.call)
        fields += adifField("QSO_DATE", q.qsoDate)
        fields += adifField("TIME_ON", q.timeOn)
        fields += optField("TIME_OFF", q.timeOff)
        fields += optField("FREQ", q.freq.map { String($0) })
        fields += optField("FREQ_RX", q.freqRx.map { String($0) })
        fields += optField("BAND", q.band?.rawValue)
        fields += optField("BAND_RX", q.bandRx?.rawValue)
        fields += optField("MODE", q.mode?.rawValue)
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
        fields += optField("TX_PWR", q.txPower.map { String($0) })
        fields += optField("RX_PWR", q.rxPower.map { String($0) })
        fields += optField("ANT_AZ", q.antAz.map { String($0) })
        fields += optField("ANT_EL", q.antEl.map { String($0) })
        fields += optField("QSL_SENT", q.qslSent)
        fields += optField("QSL_SENT_VIA", q.qslSentVia)
        fields += optField("QSL_RCVD", q.qslRcvd)
        fields += optField("QSL_RCVD_VIA", q.qslRcvdVia)
        fields += optField("LOTW_QSL_SENT", q.lotwQslSent)
        fields += optField("LOTW_QSL_RCVD", q.lotwQslRcvd)
        fields += optField("EQSL_QSL_SENT", q.eqslQslSent)
        fields += optField("EQSL_QSL_RCVD", q.eqslQslRcvd)
        fields += optField("STATION_CALLSIGN", q.stationCallsign)
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
        fields += optField("CONTEST_ID", q.contestId)
        fields += optField("SRX", q.srx.map { String($0) })
        fields += optField("STX", q.stx.map { String($0) })
        fields += optField("SRX_STRING", q.srxString)
        fields += optField("STX_STRING", q.stxString)
        fields += optField("COMMENT", q.comment)
        fields += optField("NOTES", q.notes)

        // Extra fields
        for (key, value) in q.extraFields {
            fields += adifField(key, value)
        }

        fields += "<EOR>\n"
        return fields
    }

    private func adifField(_ name: String, _ value: String) -> String {
        "<\(name):\(value.count)>\(value) "
    }

    private func optField(_ name: String, _ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "" }
        return adifField(name, value)
    }
}
