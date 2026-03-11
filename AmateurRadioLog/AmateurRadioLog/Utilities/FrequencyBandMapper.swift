import Foundation

enum FrequencyBandMapper {
    static func band(for frequency: Double) -> Band? {
        Band.from(frequencyMHz: frequency)
    }

    static func defaultFrequency(for band: Band) -> Double {
        switch band {
        case .band160m: return 1.840
        case .band80m:  return 3.573
        case .band60m:  return 5.357
        case .band40m:  return 7.074
        case .band30m:  return 10.136
        case .band20m:  return 14.074
        case .band17m:  return 18.100
        case .band15m:  return 21.074
        case .band12m:  return 24.915
        case .band10m:  return 28.074
        case .band6m:   return 50.313
        case .band4m:   return 70.100
        case .band2m:   return 144.174
        case .band1_25m: return 222.065
        case .band70cm: return 432.174
        case .band33cm: return 903.0
        case .band23cm: return 1296.174
        default: return band.frequencyRangeMHz.lowerBound
        }
    }
}
