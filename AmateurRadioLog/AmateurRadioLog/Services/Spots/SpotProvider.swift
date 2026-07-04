import Foundation

// MARK: - Provider Protocol

/// A live spot source. Providers push batches of spots through the stream
/// returned by `start()`; `stop()` ends polling and finishes the stream.
/// Future DX-cluster / RBN telnet providers conform to the same protocol —
/// a persistent connection simply yields smaller, more frequent batches.
protocol SpotProvider: Sendable {
    var source: SpotSource { get }
    /// Begins producing spots. Calling `start()` again restarts the
    /// provider and returns a fresh stream.
    func start() async -> AsyncStream<[Spot]>
    /// Stops producing and finishes the current stream.
    func stop() async
}

// MARK: - Transport (network seam for tests)

/// Minimal network seam so provider tests can inject canned responses.
protocol SpotTransport: Sendable {
    func fetch(_ request: URLRequest) async throws -> Data
}

struct URLSessionSpotTransport: SpotTransport {
    var session: URLSession = .shared

    func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Request Factory

enum SpotRequestFactory {
    /// Descriptive User-Agent — both POTA and SOTA ask API consumers to
    /// identify themselves.
    static let userAgent = "AmateurRadioLog/1.0 (https://github.com/morria/amateur-radio-log)"

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }
}

// MARK: - Shared Parsing Helpers

/// Parses the timezone-less UTC timestamps both APIs return
/// ("2026-07-04T12:34:56", with optional fractional seconds and/or a
/// trailing "Z"). Fractional digits vary (SOTA sends 7), so they are
/// stripped rather than pattern-matched.
enum SpotTimestampParser {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func date(from string: String) -> Date? {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("Z") { s.removeLast() }
        if let dot = s.firstIndex(of: ".") { s = String(s[..<dot]) }
        return formatter.date(from: s)
    }
}

/// Decodes a JSON value that may arrive as a number or a numeric string
/// (both APIs send frequencies as strings, but this guards against drift).
struct FlexibleDouble: Decodable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = Double(s.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }
}

/// Uppercased, trimmed mode token; empty → nil.
func normalizedSpotMode(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return mode.isEmpty ? nil : mode
}
