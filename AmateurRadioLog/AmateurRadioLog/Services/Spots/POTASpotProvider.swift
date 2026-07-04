import Foundation

/// Polls the POTA activator spot feed every 60 seconds.
///
/// API notes (https://api.pota.app/spot/activator):
/// - `frequency` is kHz as a string ("14067.0") → /1000 for MHz.
/// - `name` is the park name (`parkName` is usually null).
/// - `spotTime` has no timezone suffix and is UTC.
/// - `expire` is remaining lifetime in seconds from now.
actor POTASpotProvider: SpotProvider {
    static let endpoint = URL(string: "https://api.pota.app/spot/activator")!
    static let defaultTTL: TimeInterval = 1800

    nonisolated let source: SpotSource = .pota

    private let transport: any SpotTransport
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<[Spot]>.Continuation?

    init(transport: any SpotTransport = URLSessionSpotTransport(),
         pollInterval: Duration = .seconds(60)) {
        self.transport = transport
        self.pollInterval = pollInterval
    }

    func start() -> AsyncStream<[Spot]> {
        stopNow()
        let (stream, continuation) = AsyncStream<[Spot]>.makeStream()
        self.continuation = continuation
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
        return stream
    }

    func stop() { stopNow() }

    private func stopNow() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func pollOnce() async {
        do {
            let data = try await transport.fetch(SpotRequestFactory.request(for: Self.endpoint))
            continuation?.yield(Self.parse(data))
        } catch {
            // Transient poll failures are silent; the next cycle retries.
        }
    }

    // MARK: - Parsing (pure, unit-tested)

    struct DTO: Decodable {
        let spotId: Int?
        let activator: String?
        let frequency: FlexibleDouble?
        let mode: String?
        let reference: String?
        let spotTime: String?
        let spotter: String?
        let comments: String?
        let name: String?
        let grid6: String?
        let latitude: Double?
        let longitude: Double?
        let expire: Int?
    }

    static func parse(_ data: Data, now: Date = Date()) -> [Spot] {
        guard let dtos = try? JSONDecoder().decode([DTO].self, from: data) else { return [] }
        return dtos.compactMap { dto in
            guard let call = dto.activator?
                    .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  !call.isEmpty,
                  let kHz = dto.frequency?.value, kHz > 0 else { return nil }
            let nativeId = dto.spotId.map(String.init) ?? "\(call)-\(kHz)"
            let ttl = dto.expire.map(TimeInterval.init) ?? defaultTTL
            return Spot(
                id: "pota-\(nativeId)",
                activatorCall: call,
                frequencyMHz: kHz / 1000.0,
                mode: normalizedSpotMode(dto.mode),
                source: .pota,
                spotter: dto.spotter,
                comment: dto.comments,
                reference: dto.reference,
                referenceName: dto.name,
                grid: dto.grid6.flatMap { $0.isEmpty ? nil : $0 },
                latitude: dto.latitude,
                longitude: dto.longitude,
                timestamp: dto.spotTime.flatMap(SpotTimestampParser.date(from:)) ?? now,
                expiresAt: now.addingTimeInterval(ttl))
        }
    }
}
