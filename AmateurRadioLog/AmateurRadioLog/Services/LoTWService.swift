import Foundation

actor LoTWService {
    private let session: URLSession

    /// - Parameter session: transport, injectable for URLProtocol-stub tests.
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Incremental sync cursors

    /// Formats a `yyyy-MM-dd` (UTC) cursor date from a sync start date, backed
    /// off by `overlapDays` so records that arrive during a sync are not missed.
    static func cursorDate(from date: Date, overlapDays: Int = 1) -> String {
        let adjusted = date.addingTimeInterval(-Double(overlapDays) * 86400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: adjusted)
    }

    // MARK: - Download QSOs and QSL confirmations

    /// Downloads QSO records LoTW has received from this station (qso_qsl=no).
    /// When `since` (yyyy-MM-dd) is set, only QSOs received by LoTW on or after
    /// that date are returned (`qso_qsorxsince`); nil fetches the full log.
    func downloadQSOs(username: String, password: String, since: String? = nil) async throws -> [QSORecord] {
        var query: [(String, String)] = [("qso_qsl", "no")]
        if let since {
            query.append(("qso_qsorxsince", since))
        }
        return try await fetchReport(username: username, password: password, query: query)
    }

    /// Downloads QSL confirmations (qso_qsl=yes). When `since` (yyyy-MM-dd) is
    /// set, only QSLs issued on or after that date are returned (`qso_qslsince`);
    /// nil fetches all confirmations.
    func downloadConfirmations(username: String, password: String, since: String? = nil) async throws -> [QSORecord] {
        var query: [(String, String)] = [("qso_qsl", "yes")]
        if let since {
            query.append(("qso_qslsince", since))
        }
        return try await fetchReport(username: username, password: password, query: query)
    }

    private func fetchReport(username: String, password: String, query: [(String, String)]) async throws -> [QSORecord] {
        var urlStr = "https://lotw.arrl.org/lotwuser/lotwreport.adi?"
        urlStr += "login=\(username.formURLEncoded)"
        urlStr += "&password=\(password.formURLEncoded)"
        urlStr += "&qso_query=1"
        urlStr += "&qso_qsldetail=yes"
        urlStr += "&qso_mydetail=yes"

        for (key, value) in query {
            urlStr += "&\(key)=\(value.formURLEncoded)"
        }

        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, response) = try await session.data(from: url)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                throw ServiceError.authenticationFailed("Invalid LoTW credentials")
            }
            if httpResponse.statusCode != 200 {
                throw ServiceError.serverError("HTTP \(httpResponse.statusCode)")
            }
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw ServiceError.parseError("Unable to decode LoTW response")
        }

        // Check for authentication error in response
        if content.lowercased().contains("username/password incorrect") ||
           content.lowercased().contains("password incorrect") {
            throw ServiceError.authenticationFailed("Invalid LoTW username or password")
        }

        let parser = ADIFParser()
        let file = try parser.parse(string: content)
        return parser.recordsToQSORecords(file.records)
    }

    // MARK: - Upload
    // LoTW only accepts digitally signed logs. Upload therefore goes through
    // TQSL (see TQSLLauncher on macOS / export-for-TQSL on both platforms),
    // never through a raw HTTP upload from here.

    // MARK: - Verify credentials

    func verifyCredentials(username: String, password: String) async throws -> Bool {
        // Use a far-future qso_qslsince so a valid login returns an
        // essentially empty report instead of the full log.
        var urlStr = "https://lotw.arrl.org/lotwuser/lotwreport.adi?"
        urlStr += "login=\(username.formURLEncoded)"
        urlStr += "&password=\(password.formURLEncoded)"
        urlStr += "&qso_query=1&qso_qsl=yes&qso_qslsince=2999-12-31"

        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await session.data(from: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ServiceError.parseError("Unable to decode response")
        }

        if content.lowercased().contains("password incorrect") ||
           content.lowercased().contains("username/password incorrect") {
            return false
        }

        return true
    }
}
