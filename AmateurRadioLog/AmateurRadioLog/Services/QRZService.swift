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

    // MARK: - Logbook Response Helpers

    private func extractReason(from response: String, default defaultReason: String = "Unknown") -> String {
        if let range = response.range(of: "REASON=") {
            return String(response[range.upperBound...])
                .components(separatedBy: "&").first ?? defaultReason
        }
        return defaultReason
    }

    private func checkAuthError(in response: String) throws {
        if response.contains("RESULT=AUTH") {
            throw ServiceError.authenticationFailed("QRZ: \(extractReason(from: response, default: "Invalid API key"))")
        }
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

            try checkAuthError(in: responseStr)

            if responseStr.contains("RESULT=OK") || responseStr.contains("RESULT=REPLACE") {
                uploaded += 1
            } else if responseStr.contains("RESULT=FAIL") {
                lastError = extractReason(from: responseStr)
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
        request.timeoutInterval = 120

        let body = "KEY=\(apiKey)&ACTION=FETCH&OPTION=ALL,TYPE:ADIF"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let responseStr = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(data: data, encoding: .ascii) else {
            throw ServiceError.parseError("Unable to decode \(data.count) byte response (HTTP \(statusCode))")
        }

        try checkAuthError(in: responseStr)

        if responseStr.contains("RESULT=FAIL") {
            throw ServiceError.serverError("QRZ: \(extractReason(from: responseStr))")
        }

        // Find the ADIF field (case-insensitive) in the response
        let adifRange = responseStr.range(of: "ADIF=", options: .caseInsensitive)
            ?? responseStr.range(of: "&ADIF=", options: .caseInsensitive).map {
                responseStr.index($0.lowerBound, offsetBy: 1)..<$0.upperBound
            }

        if let adifRange {
            let rawAdif = String(responseStr[adifRange.upperBound...])
            // QRZ returns ADIF with HTML-encoded angle brackets
            let adifStr = rawAdif
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            if !adifStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parser = ADIFParser()
                let file = try parser.parse(string: adifStr)
                return parser.recordsToQSOs(file.records)
            }
            return []
        }

        if responseStr.contains("RESULT=OK") {
            return []
        }

        throw ServiceError.parseError("Unexpected QRZ response: \(responseStr.prefix(300))")
    }

    func logout() {
        sessionKey = nil
    }
}
