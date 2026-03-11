import Foundation

struct ServiceCredentials: Sendable, Equatable {
    var username: String
    var password: String

    var isEmpty: Bool { username.isEmpty || password.isEmpty }
}

enum ServiceType: String, CaseIterable, Sendable {
    case qrz = "QRZ.com"
    case hamqth = "HamQTH.com"
    case lotw = "LoTW"
}
