import XCTest
@testable import AmateurRadioLog

/// A provider whose first batch is gated on an external signal, so a test can
/// hold one source "still loading" while another has already delivered.
private actor GatedSpotProvider: SpotProvider {
    nonisolated let source: SpotSource
    private let spots: [Spot]
    private let releaseAfter: Duration
    private var continuation: AsyncStream<[Spot]>.Continuation?
    private var task: Task<Void, Never>?

    init(source: SpotSource, spots: [Spot], releaseAfter: Duration) {
        self.source = source
        self.spots = spots
        self.releaseAfter = releaseAfter
    }

    func start() -> AsyncStream<[Spot]> {
        let (stream, continuation) = AsyncStream<[Spot]>.makeStream()
        self.continuation = continuation
        let spots = self.spots
        let delay = self.releaseAfter
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.emit(spots)
        }
        return stream
    }

    private func emit(_ spots: [Spot]) {
        continuation?.yield(spots)
    }

    func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }
}

/// Guards the property the Spots tab depends on: a slow source must never
/// hold up a fast one. These exist because "spots take forever to load"
/// reads identically to "one source is slow" from the outside, and only a
/// test can tell the two apart.
final class SpotStreamingTests: XCTestCase {

    private func spot(id: String, call: String, source: SpotSource,
                      freq: Double) -> Spot {
        let now = Date()
        return Spot(id: id, activatorCall: call, frequencyMHz: freq,
                    mode: "CW", source: source, spotter: "TEST",
                    comment: nil, reference: nil, referenceName: nil,
                    grid: nil, latitude: nil, longitude: nil,
                    timestamp: now, expiresAt: now.addingTimeInterval(1800))
    }

    /// The core claim: with one instant provider and one that takes 3s, the
    /// instant provider's spots must be on screen long before the slow one
    /// finishes.
    func testFastProviderPublishesWhileSlowProviderStillPending() async throws {
        let store = await MainActor.run { SpotStore() }
        let fast = GatedSpotProvider(
            source: .pota,
            spots: [spot(id: "pota-1", call: "K3EW", source: .pota, freq: 14.067)],
            releaseAfter: .zero)
        let slow = GatedSpotProvider(
            source: .sota,
            spots: [spot(id: "sota-1", call: "W1AW", source: .sota, freq: 7.032)],
            releaseAfter: .seconds(3))

        let service = SpotService(store: store, providers: [fast, slow],
                                  minPublishInterval: 0.05)
        await service.start()
        defer { Task { await service.stop() } }

        // Poll for up to 1s — an order of magnitude below the slow provider's
        // 3s, so a pass cannot be explained by having waited for it.
        var published: [Spot] = []
        for _ in 0..<20 {
            published = await MainActor.run { store.spots }
            if !published.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(published.map(\.id), ["pota-1"],
                       "the fast provider's spots should render while the slow one is still pending")

        let stillPending = await MainActor.run { store.spots.contains { $0.source == .sota } }
        XCTAssertFalse(stillPending, "slow provider should not have delivered yet")
    }

    /// And the slow one must still land when it eventually arrives, merged
    /// with what was already showing rather than replacing it.
    func testSlowProviderMergesInWithoutDroppingEarlierSpots() async throws {
        let store = await MainActor.run { SpotStore() }
        let fast = GatedSpotProvider(
            source: .pota,
            spots: [spot(id: "pota-1", call: "K3EW", source: .pota, freq: 14.067)],
            releaseAfter: .zero)
        let slow = GatedSpotProvider(
            source: .sota,
            spots: [spot(id: "sota-1", call: "W1AW", source: .sota, freq: 7.032)],
            releaseAfter: .milliseconds(300))

        let service = SpotService(store: store, providers: [fast, slow],
                                  minPublishInterval: 0.05)
        await service.start()
        defer { Task { await service.stop() } }

        var ids: [String] = []
        for _ in 0..<40 {
            ids = await MainActor.run { store.spots.map(\.id).sorted() }
            if ids.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(ids, ["pota-1", "sota-1"],
                       "both sources should be merged once the slow one arrives")
    }

    /// Applying the filter at tab-appear must not make the list look settled.
    /// `lastUpdated` is what the UI reads to choose between "Waiting for
    /// spots…" and "No spots match the current filters" — stamping it before
    /// any source has reported is what made loading look finished (and so,
    /// to the operator, endless) while the first fetches were still in
    /// flight.
    func testFilterChangeBeforeAnyBatchDoesNotMarkLoaded() async throws {
        let store = await MainActor.run { SpotStore() }
        let service = SpotService(store: store, minPublishInterval: 0.05)

        var filter = SpotFilter()
        filter.bands = [.band20m]
        await service.setFilter(filter)

        // Give any scheduled publish time to land.
        try await Task.sleep(for: .milliseconds(200))

        let updated = await MainActor.run { store.lastUpdated }
        XCTAssertNil(updated,
                     "a filter change alone must not mark the list as loaded")
    }

    /// ...but the first batch must clear the indicator even when it is empty,
    /// or a genuinely quiet band would spin forever.
    func testFirstEmptyBatchMarksLoaded() async throws {
        let store = await MainActor.run { SpotStore() }
        let service = SpotService(store: store, minPublishInterval: 0.05)

        await service.ingest([])

        var updated: Date?
        for _ in 0..<40 {
            updated = await MainActor.run { store.lastUpdated }
            if updated != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(updated,
                        "an empty first batch still means the source reported")
        let spots = await MainActor.run { store.spots }
        XCTAssertTrue(spots.isEmpty)
    }

    /// Same, for a first batch whose spots are all filtered out.
    func testFirstBatchFilteredToNothingStillMarksLoaded() async throws {
        let store = await MainActor.run { SpotStore() }
        let service = SpotService(store: store, minPublishInterval: 0.05)

        var filter = SpotFilter()
        filter.bands = [.band20m]
        await service.setFilter(filter)
        // A 40 m spot against a 20 m filter — nothing survives.
        await service.ingest([spot(id: "pota-1", call: "K3EW",
                                   source: .pota, freq: 7.032)])

        var updated: Date?
        for _ in 0..<40 {
            updated = await MainActor.run { store.lastUpdated }
            if updated != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(updated,
                        "the source reported, even though the filter hid everything")
    }

    /// A provider that never produces anything must not stop the others —
    /// the failure mode if start() were ever awaited serially.
    func testDeadProviderDoesNotBlockLiveOne() async throws {
        let store = await MainActor.run { SpotStore() }
        let dead = GatedSpotProvider(source: .rbn, spots: [],
                                     releaseAfter: .seconds(3600))
        let live = GatedSpotProvider(
            source: .pota,
            spots: [spot(id: "pota-9", call: "N0CALL", source: .pota, freq: 21.030)],
            releaseAfter: .zero)

        let service = SpotService(store: store, providers: [dead, live],
                                  minPublishInterval: 0.05)
        await service.start()
        defer { Task { await service.stop() } }

        var published: [Spot] = []
        for _ in 0..<20 {
            published = await MainActor.run { store.spots }
            if !published.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(published.map(\.id), ["pota-9"],
                       "a provider that never yields must not gate the others")
    }
}
