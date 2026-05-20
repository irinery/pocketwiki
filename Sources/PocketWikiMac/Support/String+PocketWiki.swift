import Foundation

extension String {
    var pocketTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pocketReplacingMatches(pattern: String, with replacement: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: replacement)
    }

    func pocketMatches(pattern: String, options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: range)
    }

    func pocketSubstring(_ range: NSRange) -> String {
        guard let swiftRange = Range(range, in: self) else { return "" }
        return String(self[swiftRange])
    }

    func pocketTruncated(to maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength)).pocketTrimmed
    }
}
