import Foundation

enum PocketWikiDateParser {
    static func parse(_ value: String) -> Date? {
        let clean = value.pocketTrimmed
        if clean.isEmpty { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: clean) { return date }

        let formats = [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "dd/MM/yyyy",
            "dd-MM-yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: clean) {
                return date
            }
        }

        return nil
    }
}
