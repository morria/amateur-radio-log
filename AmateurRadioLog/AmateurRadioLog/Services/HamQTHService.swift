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

    func logout() {
        sessionId = nil
    }
}
