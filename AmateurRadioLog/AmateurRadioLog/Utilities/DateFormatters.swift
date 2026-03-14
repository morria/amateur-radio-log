import Foundation

enum ADIFDateFormatter {
    private static let utc = TimeZone(identifier: "UTC")!

    // Cached formatters — DateFormatter allocation is expensive
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = utc
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        f.timeZone = utc
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmm"
        f.timeZone = utc
        return f
    }()

    private static let dateTimeSecsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = utc
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = utc
        return f
    }()

    private static let displayDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeZone = utc
        return f
    }()

    static func dateString(from date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }

    static func timeString(from date: Date) -> String {
        timeOnlyFormatter.string(from: date)
    }

    static func date(from dateStr: String, timeStr: String?) -> Date? {
        if let time = timeStr {
            let formatter = time.count == 6 ? dateTimeSecsFormatter : dateTimeFormatter
            return formatter.date(from: dateStr + time)
        } else {
            return dateOnlyFormatter.date(from: dateStr)
        }
    }

    /// Parse QSO date+time into a Date (used by QSO.dateTime)
    static func dateTime(dateStr: String, timeOn: String) -> Date? {
        let formatter = timeOn.count == 6 ? dateTimeSecsFormatter : dateTimeFormatter
        return formatter.date(from: dateStr + timeOn)
    }

    /// Full display with time: "Mar 14, 2026 at 3:45 PM UTC"
    static func displayDateTime(_ date: Date) -> String {
        displayFormatter.string(from: date) + " UTC"
    }

    static func displayDate(_ dateStr: String) -> String {
        guard let date = dateOnlyFormatter.date(from: dateStr) else { return dateStr }
        return displayDateOnlyFormatter.string(from: date)
    }

    static func displayTime(_ timeStr: String) -> String {
        if timeStr.count >= 4 {
            let h = timeStr.prefix(2)
            let m = timeStr.dropFirst(2).prefix(2)
            return "\(h):\(m) UTC"
        }
        return timeStr
    }
}
