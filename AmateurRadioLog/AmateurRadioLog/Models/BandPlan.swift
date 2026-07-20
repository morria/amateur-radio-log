import Foundation

/// US amateur radio license classes, ordered by privilege. Used to filter the
/// Spots list to the frequencies the operator is actually authorized to
/// transmit on — see `BandPlan`.
enum LicenseClass: String, CaseIterable, Codable, Sendable, Identifiable {
    case technician
    case general
    case advanced
    case extra

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .technician: return String(localized: "Technician")
        case .general:    return String(localized: "General")
        case .advanced:   return String(localized: "Advanced")
        case .extra:      return String(localized: "Amateur Extra")
        }
    }

    /// Compact label for the Spots filter chip.
    var shortName: String {
        switch self {
        case .technician: return String(localized: "Tech")
        case .general:    return String(localized: "General")
        case .advanced:   return String(localized: "Advanced")
        case .extra:      return String(localized: "Extra")
        }
    }
}

/// Emission category used by the US band plan to gate frequencies: Morse
/// (`cw`), narrow-band `data` (RTTY/FT8/PSK/…), and `phone` voice/image
/// (SSB/AM/FM/SSTV/…).
enum Emission: Hashable, Sendable {
    case cw
    case data
    case phone

    private static let phoneModes: Set<String> = [
        "SSB", "USB", "LSB", "AM", "FM", "NFM", "PHONE", "VOICE", "DV",
        "DIGITALVOICE", "DSTAR", "D-STAR", "DMR", "C4FM", "FUSION", "SSTV"
    ]
    private static let dataModes: Set<String> = [
        "RTTY", "FT8", "FT4", "PSK", "PSK31", "PSK63", "JT65", "JT9", "JS8",
        "MFSK", "OLIVIA", "CONTESTI", "CONTESTIA", "HELL", "ROS", "PKT",
        "PACKET", "DATA", "DIGI", "DIGITAL", "MSK144", "Q65", "FSK441",
        "DOMINO", "THOR", "FSK"
    ]
    /// Prefixes catch parameterized variants ("PSK125", "MFSK32", "OLIVIA 8/500").
    private static let dataPrefixes = [
        "PSK", "MFSK", "OLIVIA", "CONTEST", "JT", "FT", "JS8", "RTTY",
        "THOR", "DOMINO", "Q65", "FSK", "MSK"
    ]

    /// Classifies a raw mode string (as spots report it) into an emission
    /// category, or nil when the mode is unknown — callers stay lenient
    /// rather than hide a spot they can't classify.
    static func category(forModeRaw raw: String?) -> Emission? {
        guard let raw else { return nil }
        let m = raw.uppercased().trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return nil }
        if m == "CW" { return .cw }
        if phoneModes.contains(m) { return .phone }
        if dataModes.contains(m) { return .data }
        if dataPrefixes.contains(where: { m.hasPrefix($0) }) { return .data }
        return nil
    }
}

/// The US amateur band plan by license class — enough to answer "may I
/// transmit here?" for the Spots privilege filter. Sub-band edges follow the
/// FCC Part 97 allocations (as summarized by the ARRL band chart).
enum BandPlan {
    struct Segment: Sendable {
        let range: ClosedRange<Double>
        let emissions: Set<Emission>
        init(_ low: Double, _ high: Double, _ emissions: Set<Emission>) {
            self.range = low...high
            self.emissions = emissions
        }
    }

    // CW is authorized throughout every segment, so a data or phone segment
    // includes it too.
    private static let cwData: Set<Emission> = [.cw, .data]
    private static let cwPhone: Set<Emission> = [.cw, .phone]
    private static let all: Set<Emission> = [.cw, .data, .phone]
    private static let cwOnly: Set<Emission> = [.cw]

    /// Whether `licenseClass` may transmit at `frequencyMHz` with the given
    /// raw mode. Lenient where it can't be sure: a frequency outside every
    /// recognized band, or an unknown emission that still lands inside an
    /// authorized segment, passes.
    static func canTransmit(licenseClass: LicenseClass,
                            frequencyMHz: Double, modeRaw: String?) -> Bool {
        guard let band = Band.from(frequencyMHz: frequencyMHz) else { return true }
        let segments = privileges(for: licenseClass, band: band)
        if segments.isEmpty { return false } // no privileges on this band at all
        let emission = Emission.category(forModeRaw: modeRaw)
        for segment in segments where segment.range.contains(frequencyMHz) {
            guard let emission else { return true } // in an authorized segment, mode unknown
            if segment.emissions.contains(emission) { return true }
        }
        return false
    }

    /// The authorized sub-bands for a class on a band. Empty = no privileges
    /// on that band.
    static func privileges(for licenseClass: LicenseClass, band: Band) -> [Segment] {
        switch band {
        // VHF and up: all US classes share full privileges.
        case .band6m, .band4m, .band2m, .band1_25m, .band70cm, .band33cm,
             .band23cm, .band13cm, .band9cm, .band6cm, .band3cm:
            return [fullBand(band, all)]

        // MF/LF: lenient (CW/data). Rarely spotted; avoid false hides.
        case .band2190m, .band630m, .band560m:
            return [fullBand(band, cwData)]

        case .band160m:
            return licenseClass == .technician ? [] : [Segment(1.800, 2.000, all)]

        case .band80m:
            switch licenseClass {
            case .extra:      return [Segment(3.500, 3.600, cwData), Segment(3.600, 4.000, cwPhone)]
            case .advanced:   return [Segment(3.525, 3.600, cwData), Segment(3.700, 4.000, cwPhone)]
            case .general:    return [Segment(3.525, 3.600, cwData), Segment(3.800, 4.000, cwPhone)]
            case .technician: return [Segment(3.525, 3.600, cwOnly)]
            }

        case .band60m:
            // Channelized 100 W ERP for General and up; approximated as the band.
            return licenseClass == .technician ? [] : [fullBand(band, all)]

        case .band40m:
            switch licenseClass {
            case .extra:      return [Segment(7.000, 7.125, cwData), Segment(7.125, 7.300, cwPhone)]
            case .advanced:   return [Segment(7.025, 7.125, cwData), Segment(7.125, 7.300, cwPhone)]
            case .general:    return [Segment(7.025, 7.125, cwData), Segment(7.175, 7.300, cwPhone)]
            case .technician: return [Segment(7.025, 7.125, cwOnly)]
            }

        case .band30m:
            return licenseClass == .technician ? [] : [Segment(10.100, 10.150, cwData)]

        case .band20m:
            switch licenseClass {
            case .extra:      return [Segment(14.000, 14.150, cwData), Segment(14.150, 14.350, cwPhone)]
            case .advanced:   return [Segment(14.025, 14.150, cwData), Segment(14.175, 14.350, cwPhone)]
            case .general:    return [Segment(14.025, 14.150, cwData), Segment(14.225, 14.350, cwPhone)]
            case .technician: return []
            }

        case .band17m:
            return licenseClass == .technician
                ? []
                : [Segment(18.068, 18.110, cwData), Segment(18.110, 18.168, cwPhone)]

        case .band15m:
            switch licenseClass {
            case .extra:      return [Segment(21.000, 21.200, cwData), Segment(21.200, 21.450, cwPhone)]
            case .advanced:   return [Segment(21.025, 21.200, cwData), Segment(21.225, 21.450, cwPhone)]
            case .general:    return [Segment(21.025, 21.200, cwData), Segment(21.275, 21.450, cwPhone)]
            case .technician: return [Segment(21.025, 21.200, cwOnly)]
            }

        case .band12m:
            return licenseClass == .technician
                ? []
                : [Segment(24.890, 24.930, cwData), Segment(24.930, 24.990, cwPhone)]

        case .band10m:
            // Technician gets CW/data 28.0–28.3 and SSB 28.3–28.5.
            return licenseClass == .technician
                ? [Segment(28.000, 28.300, cwData), Segment(28.300, 28.500, cwPhone)]
                : [Segment(28.000, 28.300, cwData), Segment(28.300, 29.700, cwPhone)]
        }
    }

    private static func fullBand(_ band: Band, _ emissions: Set<Emission>) -> Segment {
        Segment(band.frequencyRangeMHz.lowerBound, band.frequencyRangeMHz.upperBound, emissions)
    }
}
