import Foundation

/// Polls the SOTA spot feed every 120 seconds.
///
/// API notes (https://api2.sota.org.uk/api/spots/-1):
/// - `frequency` is MHz as a string ("14.295") → parse directly.
/// - `callsign` is the *spotter*; "RBNHOLE" marks robot spots
///   (SpotService suppresses them when a human spot exists for the key).
/// - `timeStamp` has no timezone suffix (UTC) and variable fractional digits.
/// - No expiry field → fixed 60-minute TTL from the spot timestamp.
/// - No grid or coordinates.
actor SOTASpotProvider: SpotProvider {
    static let endpoint = URL(string: "https://api2.sota.org.uk/api/spots/-1")!
    static let ttl: TimeInterval = 3600

    nonisolated let source: SpotSource = .sota

    private let transport: any SpotTransport
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<[Spot]>.Continuation?

    init(transport: any SpotTransport = URLSessionSpotTransport(),
         pollInterval: Duration = .seconds(120)) {
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
        let id: Int?
        let timeStamp: String?
        let comments: String?
        let callsign: String?
        let associationCode: String?
        let summitCode: String?
        let activatorCallsign: String?
        let frequency: FlexibleDouble?
        let mode: String?
        let summitDetails: String?
    }

    static func parse(_ data: Data, now: Date = Date()) -> [Spot] {
        guard let dtos = try? JSONDecoder().decode([DTO].self, from: data) else { return [] }
        return dtos.compactMap { dto in
            guard let call = dto.activatorCallsign?
                    .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  !call.isEmpty,
                  let mhz = dto.frequency?.value, mhz > 0 else { return nil }
            var reference: String?
            if let assoc = dto.associationCode, !assoc.isEmpty,
               let summit = dto.summitCode, !summit.isEmpty {
                reference = "\(assoc)/\(summit)"
            }
            let timestamp = dto.timeStamp.flatMap(SpotTimestampParser.date(from:)) ?? now
            let nativeId = dto.id.map(String.init) ?? "\(call)-\(mhz)"
            return Spot(
                id: "sota-\(nativeId)",
                activatorCall: call,
                frequencyMHz: mhz,
                mode: normalizedSpotMode(dto.mode),
                source: .sota,
                spotter: dto.callsign,
                comment: dto.comments,
                reference: reference,
                referenceName: dto.summitDetails,
                grid: nil,
                latitude: nil,
                longitude: nil,
                timestamp: timestamp,
                expiresAt: timestamp.addingTimeInterval(Self.ttl))
        }
    }
}
