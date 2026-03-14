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
        guard let url = URL(string: "https://logbook.qrz.com/api") else {
            throw ServiceError.networkError("Invalid URL")
        }

        let writer = ADIFWriter()
        var uploaded = 0
        var lastError: String?

        // QRZ API accepts one record per INSERT call
        for qso in qsos {
            let record = writer.writeSingleRecord(qso)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let encodedRecord = record.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? record
            let body = "KEY=\(apiKey)&ACTION=INSERT&ADIF=\(encodedRecord)"
            request.httpBody = body.data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)
            let responseStr = String(data: data, encoding: .utf8) ?? ""

            if responseStr.contains("RESULT=OK") {
                uploaded += 1
            } else if responseStr.contains("RESULT=FAIL") {
                // Extract reason
                if let range = responseStr.range(of: "REASON=") {
                    lastError = String(responseStr[range.upperBound...])
                        .components(separatedBy: "&").first
                }
            }
        }

        if uploaded == 0 && !qsos.isEmpty {
            throw ServiceError.serverError(lastError ?? "Upload failed for all QSOs")
        }

        return uploaded
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

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let responseStr = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(data: data, encoding: .ascii) else {
            throw ServiceError.parseError("Unable to decode \(data.count) byte response (HTTP \(statusCode))")
        }

        if responseStr.contains("RESULT=FAIL") {
            // Extract reason
            if let range = responseStr.range(of: "REASON=") {
                let reason = String(responseStr[range.upperBound...])
                    .components(separatedBy: "&").first ?? "Unknown"
                throw ServiceError.serverError("QRZ: \(reason)")
            }
            throw ServiceError.serverError("QRZ download failed: \(responseStr.prefix(200))")
        }

        // Response contains ADIF data after ADIF= tag
        if let adifRange = responseStr.range(of: "ADIF=") {
            let adifStr = String(responseStr[adifRange.upperBound...])
            if adifStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return []
            }
            let parser = ADIFParser()
            let file = try parser.parse(string: adifStr)
            return parser.recordsToQSOs(file.records)
        }

        // No ADIF data and no error — empty logbook
        if responseStr.contains("RESULT=OK") {
            return []
        }

        throw ServiceError.parseError("Unexpected QRZ response: \(responseStr.prefix(200))")
    }

    func logout() {
        sessionKey = nil
    }
}
