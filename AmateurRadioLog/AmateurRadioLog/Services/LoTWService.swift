import Foundation

actor LoTWService {

    // MARK: - Download QSL confirmations

    func downloadQSLs(username: String, password: String, qsoQDateSince: String? = nil) async throws -> [QSO] {
        var urlStr = "https://lotw.arrl.org/lotwuser/lotwreport.adi?"
        urlStr += "login=\(username)"
        urlStr += "&password=\(password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password)"
        urlStr += "&qso_query=1"
        urlStr += "&qso_qsl=no"
        urlStr += "&qso_qsldetail=yes"
        urlStr += "&qso_mydetail=yes"

        if let since = qsoQDateSince {
            urlStr += "&qso_qDateSince=\(since)"
        }

        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

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
        return parser.recordsToQSOs(file.records)
    }

    // MARK: - Upload QSOs (ADIF)
    // Note: LoTW normally requires digitally signed ADIF via tqsl.
    // This provides a basic ADIF upload for stations that have configured tqsl cert on the server side.
    // For full LoTW integration, users should use tqsl to sign their ADIF files.

    func uploadADIF(username: String, password: String, adifContent: String) async throws -> String {
        guard let url = URL(string: "https://lotw.arrl.org/lotwuser/upload") else {
            throw ServiceError.networkError("Invalid URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"login\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(username)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"password\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(password)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"upfile\"; filename=\"hamlog_upload.adi\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(adifContent.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw ServiceError.serverError("HTTP \(httpResponse.statusCode)")
        }

        return String(data: data, encoding: .utf8) ?? "Upload completed"
    }

    // MARK: - Verify credentials

    func verifyCredentials(username: String, password: String) async throws -> Bool {
        var urlStr = "https://lotw.arrl.org/lotwuser/lotwreport.adi?"
        urlStr += "login=\(username)"
        urlStr += "&password=\(password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password)"
        urlStr += "&qso_query=1&qso_qDateSince=29990101"

        guard let url = URL(string: urlStr) else {
            throw ServiceError.networkError("Invalid URL")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
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
