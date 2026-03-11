import Foundation

actor QRZService {
    private var sessionKey: String?
    private let xmlParser = XMLResponseParser()

    var isAuthenticated: Bool { sessionKey != nil }

    // MARK: - Authentication

    func authenticate(username: String, password: String) async throws {
        let encoded = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password
        let urlStr = "https://xmldata.qrz.com/xml/current/?username=\(username);password=\(encoded);agent=HamLog1.0"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let result = xmlParser.parse(data: data)

        if let key = result["Key"], !key.isEmpty {
            sessionKey = key
        } else if let error = result["Error"] {
            throw ServiceError.authenticationFailed(error)
        } else {
            throw ServiceError.authenticationFailed("No session key returned")
        }
    }

    // MARK: - Callsign Lookup

    func lookup(callsign: String) async throws -> CallsignLookupResult {
        guard let key = sessionKey else { throw ServiceError.notAuthenticated }

        let urlStr = "https://xmldata.qrz.com/xml/current/?s=\(key);callsign=\(callsign)"
        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let result = xmlParser.parse(data: data)

        if let error = result["Error"] {
            if error.contains("Session Timeout") || error.contains("Invalid session key") {
                sessionKey = nil
                throw ServiceError.notAuthenticated
            }
            throw ServiceError.notFound(error)
        }

        guard let call = result["call"] else {
            throw ServiceError.notFound("No data for \(callsign)")
        }

        return CallsignLookupResult(
            callsign: call,
            firstName: result["fname"],
            lastName: result["name"],
            address: result["addr1"],
            city: result["addr2"],
            state: result["state"],
            zipCode: result["zip"],
            country: result["country"],
            grid: result["grid"],
            latitude: result["lat"].flatMap { Double($0) },
            longitude: result["lon"].flatMap { Double($0) },
            county: result["county"],
            email: result["email"],
            qslVia: result["qslmgr"],
            cqZone: result["cqzone"].flatMap { Int($0) },
            ituZone: result["ituzone"].flatMap { Int($0) },
            dxcc: result["dxcc"].flatMap { Int($0) },
            lotw: result["lotw"] == "1",
            eqsl: result["eqsl"] == "1",
            continent: nil
        )
    }

    // MARK: - Logbook Upload

    func uploadQSOs(_ qsos: [QSO], apiKey: String) async throws -> Int {
        let writer = ADIFWriter()
        let adif = writer.write(qsos: qsos)

        guard let url = URL(string: "https://logbook.qrz.com/api") else {
            throw ServiceError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "KEY=\(apiKey)&ACTION=INSERT&ADIF=\(adif.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? adif)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let responseStr = String(data: data, encoding: .utf8) ?? ""

        if responseStr.contains("RESULT=OK") || responseStr.contains("COUNT=") {
            // Extract count
            if let range = responseStr.range(of: "COUNT="),
               let endRange = responseStr[range.upperBound...].rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) {
                let countStr = responseStr[range.upperBound..<endRange.lowerBound]
                return Int(countStr) ?? qsos.count
            }
            return qsos.count
        } else if responseStr.contains("RESULT=FAIL") {
            throw ServiceError.serverError(responseStr)
        }

        return 0
    }

    // MARK: - Logbook Download

    func downloadQSOs(apiKey: String) async throws -> [QSO] {
        guard let url = URL(string: "https://logbook.qrz.com/api") else {
            throw ServiceError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "KEY=\(apiKey)&ACTION=FETCH&OPTION=ALL"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let responseStr = String(data: data, encoding: .utf8) else {
            throw ServiceError.parseError("Unable to decode response")
        }

        // Response contains ADIF data after ADIF= tag
        if let adifRange = responseStr.range(of: "ADIF=") {
            let adifStr = String(responseStr[adifRange.upperBound...])
            let parser = ADIFParser()
            let file = try parser.parse(string: adifStr)
            return parser.recordsToQSOs(file.records)
        }

        if responseStr.contains("RESULT=FAIL") {
            throw ServiceError.serverError(responseStr)
        }

        return []
    }

    func logout() {
        sessionKey = nil
    }
}
