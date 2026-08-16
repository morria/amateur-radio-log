import Foundation

// MARK: - Preferences

/// Wavelog connection settings.
///
/// UserDefaults-backed rather than AppSettings/CloudKit, for the same reason
/// as the rig and WSJT-X preferences: a self-hosted instance is reached by a
/// host name that differs per device and per network (a Tailscale name from
/// the phone, a LAN address from the shack Mac). Syncing one URL to every
/// device would break whichever device isn't on that path. The API key is
/// never stored here — it lives in the Keychain.
enum WavelogPreferences {
    static let enabledKey = "wavelogEnabled"
    static let urlKey = "wavelogURL"
    static let stationProfileKey = "wavelogStationProfileId"
    static let keychainAccount = "wavelog-api-key"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var urlString: String {
        (UserDefaults.standard.string(forKey: urlKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var stationProfileId: String {
        (UserDefaults.standard.string(forKey: stationProfileKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// API keys are secrets, so they go to the Keychain like every other
    /// service credential rather than into UserDefaults.
    static var apiKey: String {
        KeychainManager.load(account: keychainAccount) ?? ""
    }

    static func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainManager.delete(account: keychainAccount)
        } else {
            try KeychainManager.save(account: keychainAccount, password: trimmed)
        }
    }

    static var configuration: WavelogService.Configuration? {
        WavelogService.Configuration(urlString: urlString,
                                     apiKey: apiKey,
                                     stationProfileId: stationProfileId)
    }

    /// Configured enough to attempt a sync.
    static var isConfigured: Bool {
        enabled && configuration != nil && !stationProfileId.isEmpty
    }
}

// MARK: - Station Profile

/// One of the station profiles defined in Wavelog. A QSO is filed against a
/// profile, which supplies the station callsign, grid and DXCC — so the app
/// has to know which one to upload into.
struct WavelogStationProfile: Sendable, Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let callsign: String
    let gridsquare: String
    let isActive: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "station_id"
        case name = "station_profile_name"
        case callsign = "station_callsign"
        case gridsquare = "station_gridsquare"
        case isActive = "station_active"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        callsign = (try? c.decode(String.self, forKey: .callsign)) ?? ""
        gridsquare = (try? c.decode(String.self, forKey: .gridsquare)) ?? ""
        // Wavelog sends these flags as "1"/"0" strings.
        isActive = ((try? c.decode(String.self, forKey: .isActive)) ?? "0") == "1"
    }

    /// "Brooklyn — W2ASM" for the picker.
    var displayName: String {
        callsign.isEmpty ? name : "\(name) — \(callsign)"
    }
}

// MARK: - Service

/// Wavelog (self-hosted logbook) client.
///
/// Wavelog's API is a small set of endpoints under `/api` on the instance
/// root, keyed by an API key rather than a session. Only three matter here:
/// `auth` to validate the key, `station_info` to list the profiles a QSO can
/// be filed against, and `qso` to insert ADIF.
actor WavelogService {

    struct Configuration: Sendable, Equatable {
        let baseURL: URL
        let apiKey: String
        let stationProfileId: String

        /// Fails rather than guessing when the URL is unusable.
        ///
        /// Accepts what a person actually pastes: a bare host, a trailing
        /// slash, or the `/index.php` some installs sit behind. Everything is
        /// normalized to the instance root so endpoint paths can be appended
        /// blindly.
        init?(urlString: String, apiKey: String, stationProfileId: String = "") {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }

            var text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // A bare "lepton:8086" parses as scheme "lepton", so require an
            // explicit scheme and default to http (self-hosted instances are
            // routinely plain HTTP on a private network).
            if !text.lowercased().hasPrefix("http://"),
               !text.lowercased().hasPrefix("https://") {
                text = "http://" + text
            }
            while text.hasSuffix("/") { text.removeLast() }
            if text.lowercased().hasSuffix("/index.php") {
                text.removeLast("/index.php".count)
            }
            guard let url = URL(string: text), url.host != nil else { return nil }

            self.baseURL = url
            self.apiKey = key
            self.stationProfileId = stationProfileId.trimmingCharacters(in: .whitespaces)
        }

        func endpoint(_ path: String) -> URL {
            baseURL.appendingPathComponent("api").appendingPathComponent(path)
        }
    }

    enum WavelogError: Error, LocalizedError, Equatable {
        case invalidConfiguration
        case invalidKey
        case readOnlyKey
        case noStationProfile
        case httpStatus(Int)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return String(localized: "Enter your Wavelog URL and API key")
            case .invalidKey:
                return String(localized: "Wavelog rejected the API key")
            case .readOnlyKey:
                return String(localized: "This API key is read-only — uploading needs a read/write key")
            case .noStationProfile:
                return String(localized: "Choose a station profile to log into")
            case .httpStatus(let code):
                return String(localized: "Wavelog returned HTTP \(code)")
            case .badResponse(let detail):
                return String(localized: "Unexpected reply from Wavelog: \(detail)")
            }
        }
    }

    /// Result of an auth probe.
    struct AuthInfo: Sendable, Equatable {
        /// Wavelog reports "rw" or "r".
        let rights: String
        var canWrite: Bool { rights.lowercased().contains("w") }
    }

    /// Station-location fields withheld from uploads.
    ///
    /// Wavelog files every QSO under a station profile, which *is* the
    /// station's location — and it rejects any record whose `MY_GRIDSQUARE`
    /// disagrees with that profile's locator:
    ///
    ///     Differing locator FN30ar while importing QSO with W4DGA
    ///     for station locator FN30AQ : SKIPPED
    ///
    /// A log accumulates per-QSO grids that differ for entirely ordinary
    /// reasons — a GPS fix that lands one subsquare over, or a portable
    /// operation — and each one silently cost an upload. Sending only the
    /// contact's own data and letting the profile supply the station's is
    /// what Wavelog's model actually asks for.
    ///
    /// The trade: a QSO made portable from another grid is filed under the
    /// selected profile's location. Operators who want those kept apart
    /// should make a station profile per location and sync them separately —
    /// which is Wavelog's intended way to express it.
    static let stationFields: Set<String> = [
        "MY_GRIDSQUARE", "MY_CITY", "MY_STATE", "MY_COUNTRY",
        "MY_CQ_ZONE", "MY_ITU_ZONE",
    ]

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Auth

    /// Validates the key. `auth` answers XML rather than JSON — the one
    /// endpoint in this set that does.
    func validate(_ config: Configuration) async throws -> AuthInfo {
        let (data, response) = try await session.data(
            from: config.endpoint("auth").appendingPathComponent(config.apiKey))
        try Self.checkStatus(response)
        let body = String(decoding: data, as: UTF8.self)
        guard let status = Self.xmlValue("status", in: body) else {
            throw WavelogError.badResponse(String(body.prefix(120)))
        }
        guard status.caseInsensitiveCompare("Valid") == .orderedSame else {
            throw WavelogError.invalidKey
        }
        return AuthInfo(rights: Self.xmlValue("rights", in: body) ?? "")
    }

    // MARK: Station profiles

    func stationProfiles(_ config: Configuration) async throws -> [WavelogStationProfile] {
        let (data, response) = try await session.data(
            from: config.endpoint("station_info").appendingPathComponent(config.apiKey))
        try Self.checkStatus(response)
        do {
            return try JSONDecoder().decode([WavelogStationProfile].self, from: data)
        } catch {
            // An invalid key answers with a JSON object, not an array.
            throw WavelogError.badResponse(String(String(decoding: data, as: UTF8.self).prefix(120)))
        }
    }

    // MARK: Upload

    /// Uploads records one at a time.
    ///
    /// Sequential on purpose: Wavelog's insert is a synchronous write on a
    /// self-hosted box that may be a Raspberry Pi, and its duplicate check
    /// reads the same table it writes. Parallel inserts buy little and risk
    /// hammering someone's home server — this is a background sync, not an
    /// interactive one.
    func uploadQSOs(_ qsos: [QSORecord], config: Configuration,
                    progress: SyncProgressHandler? = nil) async throws -> UploadResult {
        guard !config.stationProfileId.isEmpty else { throw WavelogError.noStationProfile }

        let writer = ADIFWriter()
        var result = UploadResult()
        let total = qsos.count

        for (index, qso) in qsos.enumerated() {
            try Task.checkCancellation()
            // Upload candidates always carry a uuid (QSOStore mints one
            // before handing records out); the fallback never matches back.
            let id = qso.uuid ?? UUID()
            do {
                let record = writer.writeSingleRecord(qso, omitting: Self.stationFields)
                switch try await insert(record, config: config) {
                case .success:
                    result.succeeded.append(id)
                case .duplicate:
                    result.duplicates.append(id)
                case .failure(let reason):
                    result.failures.append(SyncFailure(id: id, call: qso.call, reason: reason))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failures.append(
                    SyncFailure(id: id, call: qso.call,
                                reason: error.localizedDescription))
            }
            if let progress { await progress(index + 1, total) }
        }
        return result
    }

    enum InsertOutcome: Equatable {
        case success
        case duplicate
        case failure(String)
    }

    private func insert(_ adif: String, config: Configuration) async throws -> InsertOutcome {
        var request = URLRequest(url: config.endpoint("qso"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": config.apiKey,
            "station_profile_id": config.stationProfileId,
            "type": "adif",
            "string": adif,
        ])

        let (data, response) = try await session.data(for: request)
        // Deliberately NOT status-checked.
        //
        // Wavelog answers 400 for any batch it aborts — and a duplicate is an
        // abort. The real verdict is only in the JSON body, so treating the
        // status code as the signal turns every already-uploaded contact into
        // a hard failure and hides the reason for the genuine ones. The body
        // is authoritative; the status is not.
        if let outcome = Self.outcomeIfParseable(data) { return outcome }
        // No usable body (a proxy error page, a 500, an empty reply) — then
        // the status code is all there is.
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw WavelogError.httpStatus(http.statusCode)
        }
        return Self.outcome(fromInsertReply: data)
    }

    // MARK: - Reply parsing (pure, unit-tested)

    /// Maps an `/api/qso` reply to an outcome.
    ///
    /// Wavelog answers `status: created` on success and `status: abort` for a
    /// rejected batch, with the reason only in a `messages` array of HTML
    /// fragments. A duplicate is not an error for our purposes — the QSO is
    /// in Wavelog, which is the point — so it is detected from that text and
    /// reported separately, exactly like the QRZ and HamQTH adapters.
    /// The outcome when the body is Wavelog's own JSON, or nil when it isn't
    /// (so the caller can fall back to the HTTP status).
    nonisolated static func outcomeIfParseable(_ data: Data) -> InsertOutcome? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              json["status"] is String else { return nil }
        return outcome(fromInsertReply: data)
    }

    nonisolated static func outcome(fromInsertReply data: Data) -> InsertOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            return .failure(String(String(decoding: data, as: UTF8.self).prefix(120)))
        }
        let status = (json["status"] as? String ?? "").lowercased()
        let messages = (json["messages"] as? [String] ?? [])
            .map { Self.strippingHTML($0) }
            .filter { !$0.isEmpty }

        if status == "created", (json["adif_errors"] as? Int ?? 0) == 0 {
            return .success
        }
        let joined = messages.joined(separator: "; ")
        if joined.range(of: "duplicate", options: .caseInsensitive) != nil {
            return .duplicate
        }
        if status == "failed", let reason = json["reason"] as? String {
            return .failure(reason)
        }
        return .failure(joined.isEmpty ? String(localized: "Wavelog rejected the record") : joined)
    }

    /// Wavelog embeds `<br>` and occasionally other markup in its messages.
    nonisolated static func strippingHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: " ",
                                  options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Minimal single-tag extractor for the XML `auth` reply.
    nonisolated static func xmlValue(_ tag: String, in body: String) -> String? {
        guard let open = body.range(of: "<\(tag)>"),
              let close = body.range(of: "</\(tag)>",
                                     range: open.upperBound..<body.endIndex) else { return nil }
        return String(body[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw WavelogError.httpStatus(http.statusCode)
        }
    }
}
