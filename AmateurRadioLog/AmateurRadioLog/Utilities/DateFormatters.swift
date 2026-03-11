import Foundation

enum ADIFDateFormatter {
    private static let utc = TimeZone(identifier: "UTC")!

    static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = utc
        return f.string(from: date)
    }

    static func timeString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        f.timeZone = utc
        return f.string(from: date)
    }

    static func date(from dateStr: String, timeStr: String?) -> Date? {
        let f = DateFormatter()
        f.timeZone = utc
        if let time = timeStr {
            f.dateFormat = time.count == 6 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"
            return f.date(from: dateStr + time)
        } else {
            f.dateFormat = "yyyyMMdd"
            return f.date(from: dateStr)
        }
    }

    static func displayDate(_ dateStr: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = utc
        guard let date = f.date(from: dateStr) else { return dateStr }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeZone = utc
        return out.string(from: date)
    }

    static func displayTime(_ timeStr: String) -> String {
        if timeStr.count == 6 {
            let h = timeStr.prefix(2)
            let m = timeStr.dropFirst(2).prefix(2)
            return "\(h):\(m) UTC"
        } else if timeStr.count == 4 {
            let h = timeStr.prefix(2)
            let m = timeStr.dropFirst(2).prefix(2)
            return "\(h):\(m) UTC"
        }
        return timeStr
    }
}
