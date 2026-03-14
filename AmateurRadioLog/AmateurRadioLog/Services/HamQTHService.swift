import Foundation

actor HamQTHService {
    private var sessionId: String?
    private let xmlParser = XMLResponseParser()

    var isAuthenticated: Bool { sessionId != nil }

    // MARK: - Authentication

    func authenticate(username: String, password: String) async throws {
        let encoded = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password
        let urlStr = "https://www.hamqth.com/xml.php?u=\(username)&p=\(encoded)"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let result = xmlParser.parse(data: data)

        if let sid = result["session_id"], !sid.isEmpty {
            sessionId = sid
        } else if let error = result["error"] {
            throw ServiceError.authenticationFailed(error)
        } else {
            throw ServiceError.authenticationFailed("No session ID returned")
        }
    }

    // MARK: - Callsign Lookup

    func lookup(callsign: String) async throws -> CallsignLookupResult {
        guard let sid = sessionId else { throw ServiceError.notAuthenticated }

        let urlStr = "https://www.hamqth.com/xml.php?id=\(sid)&callsign=\(callsign)&prg=HamLog"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let result = xmlParser.parse(data: data)

        if let error = result["error"] {
            if error.contains("Session does not exist") {
                sessionId = nil
                throw ServiceError.notAuthenticated
            }
            throw ServiceError.notFound(error)
        }

        guard let call = result["callsign"] else {
            throw ServiceError.notFound("No data for \(callsign)")
        }

        return CallsignLookupResult(
            callsign: call,
            firstName: result["nick"],
            lastName: result["adr_name"],
            address: result["adr_street1"],
            city: result["adr_city"],
            state: result["us_state"],
            zipCode: result["adr_zip"],
            country: result["country"],
            grid: result["grid"],
            latitude: result["latitude"].flatMap { Double($0) },
            longitude: result["longitude"].flatMap { Double($0) },
            county: result["us_county"],
            email: result["email"],
            qslVia: result["qsl_via"],
            cqZone: result["cq"].flatMap { Int($0) },
            ituZone: result["itu"].flatMap { Int($0) },
            dxcc: nil,
            lotw: result["lotw"] == "Y" || result["lotw"] == "1",
            eqsl: result["eqsl"] == "Y" || result["eqsl"] == "1",
            continent: result["continent"]
        )
    }

    // MARK: - Logbook Upload

    func uploadQSOs(_ qsos: [QSO], username: String, password: String) async throws -> Int {
        guard let url = URL(string: "https://www.hamqth.com/qso_realtime.php") else {
            throw ServiceError.networkError("Invalid URL")
        }

        let writer = ADIFWriter()
        var uploaded = 0
        var lastError: String?

        for qso in qsos {
            let record = writer.writeSingleRecord(qso)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let encodedRecord = record.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? record
            let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
            let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password
            let body = "u=\(encodedUser)&p=\(encodedPass)&cmd=insert&prg=AmateurRadioLog&adif=\(encodedRecord)"
            request.httpBody = body.data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if statusCode == 200 {
                uploaded += 1
            } else {
                lastError = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            }
        }

        if uploaded == 0 && !qsos.isEmpty {
            throw ServiceError.serverError(lastError ?? "Upload failed for all QSOs")
        }

        return uploaded
    }

    // MARK: - Logbook Download

    func downloadQSOs(username: String, password: String) async throws -> [QSO] {
        let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password
        let urlStr = "https://www.hamqth.com/adif.php?u=\(encodedUser)&p=\(encodedPass)&prg=AmateurRadioLog"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let adifStr = String(data: data, encoding: .utf8), !adifStr.isEmpty else {
            return []
        }

        let parser = ADIFParser()
        let file = try parser.parse(string: adifStr)
        return parser.recordsToQSOs(file.records)
    }

    func logout() {
        sessionId = nil
    }
}
