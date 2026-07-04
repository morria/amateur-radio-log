import Foundation

/// Posts self-spots to the POTA spot endpoint (https://api.pota.app/spot).
///
/// The endpoint is unauthenticated and unofficial (the same one pota.app's
/// web spotter uses), so callers must treat failures as expected: never
/// block logging on a spot, and surface a visible retry instead of an alert.
/// Standalone by design — it is not a `SpotProvider` and does not register
/// with `SpotService`.
actor SpotSubmitter {
    static let endpoint = URL(string: "https://api.pota.app/spot")!

    private let transport: any SpotTransport

    init(transport: any SpotTransport = URLSessionSpotTransport()) {
        self.transport = transport
    }

    /// Submits one self-spot. `frequencyMHz` is converted to the kHz string
    /// the API expects. Throws on any transport/HTTP failure.
    func submit(activator: String,
                spotter: String,
                frequencyMHz: Double,
                reference: String,
                mode: String?,
                comments: String?) async throws {
        let request = try Self.makeRequest(
            activator: activator, spotter: spotter, frequencyMHz: frequencyMHz,
            reference: reference, mode: mode, comments: comments)
        _ = try await transport.fetch(request)
    }

    // MARK: - Request building (pure, unit-tested)

    struct Payload: Codable, Sendable, Equatable {
        var activator: String
        var spotter: String
        /// Frequency in kHz, as a string — matches the web spotter's format.
        var frequency: String
        var reference: String
        var mode: String
        var source: String
        var comments: String
    }

    static func makePayload(activator: String,
                            spotter: String,
                            frequencyMHz: Double,
                            reference: String,
                            mode: String?,
                            comments: String?) -> Payload {
        let kHz = frequencyMHz * 1000.0
        // Trim a trailing ".0" so 14285.0 posts as "14285" like the web app,
        // while 14285.5 keeps its decimal.
        let freqString = kHz.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(kHz))
            : String(format: "%.1f", kHz)
        return Payload(
            activator: activator.trimmingCharacters(in: .whitespaces).uppercased(),
            spotter: spotter.trimmingCharacters(in: .whitespaces).uppercased(),
            frequency: freqString,
            reference: reference.trimmingCharacters(in: .whitespaces).uppercased(),
            mode: mode?.trimmingCharacters(in: .whitespaces).uppercased() ?? "",
            source: "AmateurRadioLog",
            comments: comments?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    static func makeRequest(activator: String,
                            spotter: String,
                            frequencyMHz: Double,
                            reference: String,
                            mode: String?,
                            comments: String?) throws -> URLRequest {
        let payload = makePayload(
            activator: activator, spotter: spotter, frequencyMHz: frequencyMHz,
            reference: reference, mode: mode, comments: comments)
        var request = SpotRequestFactory.request(for: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(payload)
        return request
    }
}
