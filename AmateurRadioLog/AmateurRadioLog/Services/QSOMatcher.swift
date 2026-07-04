import Foundation

/// Matches a QSO against a set of existing QSOs for deduplication and
/// sync reconciliation. Used by all sync paths (LoTW, QRZ, HamQTH) and
/// ADIF import.
///
/// Matching is tiered, strongest identity first:
/// 1. `uuid` equality — exact identity for records that round-tripped
///    through this app (ADIF `APP_AMATEURRADIOLOG_UUID`).
/// 2. `qrzLogId` equality — exact identity for records known to QRZ.
/// 3. Composite call + qsoDate + timeOn(HHMM) + band — fuzzy last resort
///    for external records.
///
/// Each tier only fires when the probe carries that identity; a missing or
/// non-matching identity falls through to the next tier.
enum QSOMatcher {
    static func findMatch(for qso: QSO, in existingQSOs: [QSO]) -> QSO? {
        // Tier 1: stable UUID identity
        if let uuid = qso.uuid,
           let match = existingQSOs.first(where: { $0.uuid == uuid }) {
            return match
        }

        // Tier 2: QRZ logbook record ID
        if let logId = qso.qrzLogId,
           let match = existingQSOs.first(where: { $0.qrzLogId == logId }) {
            return match
        }

        // Tier 3: composite key (call + date + HHMM + band)
        let timePrefix = String(qso.timeOn.prefix(4))
        let band = qso.bandRaw ?? ""
        return existingQSOs.first { existing in
            existing.call == qso.call
                && existing.qsoDate == qso.qsoDate
                && String(existing.timeOn.prefix(4)) == timePrefix
                && (existing.bandRaw ?? "") == band
        }
    }

    static func isDuplicate(_ qso: QSO, in existingQSOs: [QSO]) -> Bool {
        findMatch(for: qso, in: existingQSOs) != nil
    }
}
