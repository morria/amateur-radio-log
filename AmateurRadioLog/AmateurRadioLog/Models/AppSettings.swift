import Foundation
import SwiftData

@Model
final class AppSettings {
    var stationCallsign: String = ""
    var myGridsquare: String = ""
    var defaultBand: String = "20m"
    var defaultMode: String = "SSB"
    var lastBand: String?
    var lastMode: String?
    var lastFreq: Double?
    var lastPower: Double?

    init() {}

    /// Fetch the singleton settings record, creating one if needed.
    /// Migrates values from NSUbiquitousKeyValueStore on first creation.
    static func shared(context: ModelContext) -> AppSettings {
        let all = (try? context.fetch(FetchDescriptor<AppSettings>())) ?? []

        if let first = all.first {
            // Deduplicate if CloudKit created multiple records
            for extra in all.dropFirst() {
                context.delete(extra)
            }
            return first
        }

        // First launch — migrate from NSUbiquitousKeyValueStore
        let settings = AppSettings()
        let cloud = NSUbiquitousKeyValueStore.default
        settings.stationCallsign = cloud.string(forKey: "stationCallsign") ?? ""
        settings.myGridsquare = cloud.string(forKey: "myGridsquare") ?? ""
        settings.defaultBand = cloud.string(forKey: "defaultBand") ?? "20m"
        settings.defaultMode = cloud.string(forKey: "defaultMode") ?? "SSB"
        settings.lastBand = cloud.string(forKey: "lastBand")
        settings.lastMode = cloud.string(forKey: "lastMode")
        let freq = cloud.double(forKey: "lastFreq")
        settings.lastFreq = freq == 0 ? nil : freq
        let power = cloud.double(forKey: "lastPower")
        settings.lastPower = power == 0 ? nil : power
        context.insert(settings)
        return settings
    }
}
