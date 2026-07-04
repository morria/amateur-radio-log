import Foundation
import Observation

/// Main-actor snapshot of the current spots. `SpotService` publishes
/// coalesced snapshots here at most ~once per second, so per-spot events
/// never hit SwiftUI directly.
@MainActor
@Observable
final class SpotStore {
    /// Filtered, unexpired snapshot, newest first.
    var spots: [Spot] = []
    /// When the last snapshot was published.
    var lastUpdated: Date?
    /// True while the providers are polling (Spots tab visible).
    var isPolling = false
}
