import Foundation

enum Band: String, CaseIterable, Codable, Sendable, Identifiable {
    case band2190m = "2190m"
    case band630m  = "630m"
    case band560m  = "560m"
    case band160m  = "160m"
    case band80m   = "80m"
    case band60m   = "60m"
    case band40m   = "40m"
    case band30m   = "30m"
    case band20m   = "20m"
    case band17m   = "17m"
    case band15m   = "15m"
    case band12m   = "12m"
    case band10m   = "10m"
    case band6m    = "6m"
    case band4m    = "4m"
    case band2m    = "2m"
    case band1_25m = "1.25m"
    case band70cm  = "70cm"
    case band33cm  = "33cm"
    case band23cm  = "23cm"
    case band13cm  = "13cm"
    case band9cm   = "9cm"
    case band6cm   = "6cm"
    case band3cm   = "3cm"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var frequencyRangeMHz: ClosedRange<Double> {
        switch self {
        case .band2190m: return 0.1357...0.1378
        case .band630m:  return 0.472...0.479
        case .band560m:  return 0.501...0.504
        case .band160m:  return 1.8...2.0
        case .band80m:   return 3.5...4.0
        case .band60m:   return 5.3305...5.4065
        case .band40m:   return 7.0...7.3
        case .band30m:   return 10.1...10.15
        case .band20m:   return 14.0...14.35
        case .band17m:   return 18.068...18.168
        case .band15m:   return 21.0...21.45
        case .band12m:   return 24.89...24.99
        case .band10m:   return 28.0...29.7
        case .band6m:    return 50.0...54.0
        case .band4m:    return 70.0...71.0
        case .band2m:    return 144.0...148.0
        case .band1_25m: return 222.0...225.0
        case .band70cm:  return 420.0...450.0
        case .band33cm:  return 902.0...928.0
        case .band23cm:  return 1240.0...1300.0
        case .band13cm:  return 2300.0...2450.0
        case .band9cm:   return 3300.0...3500.0
        case .band6cm:   return 5650.0...5925.0
        case .band3cm:   return 10000.0...10500.0
        }
    }

    static func from(frequencyMHz: Double) -> Band? {
        allCases.first { $0.frequencyRangeMHz.contains(frequencyMHz) }
    }

    static let hfBands: [Band] = [.band160m, .band80m, .band60m, .band40m, .band30m, .band20m, .band17m, .band15m, .band12m, .band10m]
    static let vhfBands: [Band] = [.band6m, .band4m, .band2m, .band1_25m]
    static let uhfBands: [Band] = [.band70cm, .band33cm, .band23cm, .band13cm, .band9cm, .band6cm, .band3cm]
}
