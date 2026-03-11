import Foundation
import SwiftData

#if DEBUG
extension QSO {
    static var preview: QSO {
        let q = QSO(call: "W1AW", qsoDate: "20260308", timeOn: "143000")
        q.freq = 14.074
        q.band = .band20m
        q.mode = .ft8
        q.rstSent = "-10"
        q.rstRcvd = "-12"
        q.name = "ARRL HQ"
        q.qth = "Newington"
        q.gridsquare = "FN31pr"
        q.country = "United States"
        q.state = "CT"
        q.latitude = 41.714775
        q.longitude = -72.727260
        return q
    }
}
#endif
