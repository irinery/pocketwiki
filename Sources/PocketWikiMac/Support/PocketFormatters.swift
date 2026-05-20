import Foundation

enum PocketFormatters {
    static func date(_ value: Date?) -> String {
        guard let value else { return "sem data" }
        return makeDateTimeFormatter().string(from: value)
    }

    private static func makeDateTimeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}
