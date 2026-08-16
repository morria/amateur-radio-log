import Foundation

/// Merges spot batches from all registered providers, dedupes them by
/// (activator, frequency rounded to 0.1 kHz, source), drops expired spots,
/// applies the active `SpotFilter`, and publishes coalesced snapshots
/// (max ~1/sec) to the main-actor `SpotStore`.
actor SpotService {
    private let store: SpotStore?
    private let providers: [any SpotProvider]
    private let minPublishInterval: TimeInterval
    /// Injectable clock so expiry tests are deterministic.
    private let now: @Sendable () -> Date

    private var spotsByKey: [SpotKey: Spot] = [:]
    private var filter = SpotFilter()
    private var consumeTasks: [Task<Void, Never>] = []
    private var expiryTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var lastPublish: Date = .distantPast
    private(set) var isRunning = false

    /// True once at least one provider has delivered a batch — even an empty
    /// one.
    ///
    /// Until then the store's `lastUpdated` stays nil, which is what lets the
    /// UI tell "still loading" apart from "loaded, and nothing matched".
    /// Without this, applying the filter at tab-appear publishes an empty
    /// snapshot before any network call has returned, and the list claims
    /// "No spots match the current filters" while it is in fact still
    /// waiting — indistinguishable, to the operator, from loading forever.
    private var didReceiveAnyBatch = false

    init(store: SpotStore? = nil,
         providers: [any SpotProvider] = [],
         minPublishInterval: TimeInterval = 1.0,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.providers = providers
        self.minPublishInterval = minPublishInterval
        self.now = now
    }

    // MARK: - Lifecycle

    /// Starts all providers and consumes their streams. No-op when already
    /// running. Polling should only run while the Spots tab is visible.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        if let store {
            Task { @MainActor in store.isPolling = true }
        }
        for provider in providers {
            consumeTasks.append(Task { [weak self] in
                let stream = await provider.start()
                for await batch in stream {
                    guard let self else { return }
                    await self.ingest(batch)
                }
            })
        }
        // Periodic sweep so spots vanish even when no new batches arrive.
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                await self.pruneExpired()
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        for provider in providers { await provider.stop() }
        consumeTasks.forEach { $0.cancel() }
        consumeTasks = []
        expiryTask?.cancel()
        expiryTask = nil
        publishTask?.cancel()
        publishTask = nil
        if let store {
            await MainActor.run { store.isPolling = false }
        }
    }

    // MARK: - Filter

    func setFilter(_ newFilter: SpotFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        schedulePublish()
    }

    // MARK: - Merge / Dedupe

    /// Merges a provider batch. Rules per key:
    /// - already-expired spots are dropped,
    /// - a human spot always beats a robot (RBNHOLE) spot,
    /// - a robot spot never replaces a human spot,
    /// - otherwise the newest timestamp wins.
    func ingest(_ batch: [Spot]) {
        let reference = now()
        // The first batch always publishes, even when it is empty or every
        // spot in it is filtered out: that transition is what clears the
        // loading indicator.
        var changed = !didReceiveAnyBatch
        didReceiveAnyBatch = true
        for spot in batch {
            guard !spot.isExpired(at: reference) else { continue }
            let key = spot.dedupeKey
            if let existing = spotsByKey[key] {
                if existing.isHumanSpotted && !spot.isHumanSpotted { continue }
                if !existing.isHumanSpotted && spot.isHumanSpotted {
                    spotsByKey[key] = spot
                    changed = true
                    continue
                }
                if spot.timestamp >= existing.timestamp && spot != existing {
                    spotsByKey[key] = spot
                    changed = true
                }
            } else {
                spotsByKey[key] = spot
                changed = true
            }
        }
        if changed { schedulePublish() }
    }

    func pruneExpired() {
        let reference = now()
        let before = spotsByKey.count
        spotsByKey = spotsByKey.filter { !$0.value.isExpired(at: reference) }
        if spotsByKey.count != before { schedulePublish() }
    }

    /// Current filtered, unexpired snapshot, newest first (id tie-break for
    /// deterministic ordering). Used by publish and directly by tests.
    func snapshot() -> [Spot] {
        let reference = now()
        return spotsByKey.values
            .filter { !$0.isExpired(at: reference) && filter.matches($0) }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id < $1.id
            }
    }

    // MARK: - Coalesced Publishing

    /// Schedules a snapshot push to the store, coalescing bursts so the
    /// main actor sees at most ~one update per `minPublishInterval`.
    private func schedulePublish() {
        guard store != nil, publishTask == nil else { return }
        let elapsed = now().timeIntervalSince(lastPublish)
        let delay = max(0, minPublishInterval - elapsed)
        publishTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            await self.publishNow()
        }
    }

    private func publishNow() async {
        publishTask = nil
        lastPublish = now()
        guard let store else { return }
        let snap = snapshot()
        // Only stamp `lastUpdated` once a source has actually reported —
        // a filter change on its own must not make an empty list look
        // settled while the first fetches are still in flight.
        let loaded = didReceiveAnyBatch
        await MainActor.run {
            store.spots = snap
            if loaded { store.lastUpdated = Date() }
        }
    }
}
