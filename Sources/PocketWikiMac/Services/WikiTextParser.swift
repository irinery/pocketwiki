import Foundation

enum WikiTextParser {
    static func slugify(_ text: String) -> String {
        var clean = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        clean = removeWikiExtension(clean)
        if let fragment = clean.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            clean = String(clean[..<fragment])
        }
        clean = clean.replacingOccurrences(of: "\\", with: "/").pocketTrimmed

        var scalars: [UnicodeScalar] = []
        var previous: UnicodeScalar?

        for scalar in clean.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isNumber = value >= 48 && value <= 57
            let isSeparator = CharacterSet.whitespacesAndNewlines.contains(scalar)
            let allowed = isLetter || isNumber || scalar == "/" || scalar == "_" || scalar == "-"

            if isSeparator {
                if previous != "-" { scalars.append("-") }
                previous = "-"
            } else if allowed {
                if scalar == "-" && previous == "-" { continue }
                if scalar == "/" && previous == "/" { continue }
                scalars.append(scalar)
                previous = scalar
            }
        }

        var result = String(String.UnicodeScalarView(scalars))
        while result.hasPrefix("/") || result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("/") || result.hasSuffix("-") { result.removeLast() }
        return result
    }

    static func pathToSlug(_ path: String) -> String {
        var clean = path.replacingOccurrences(of: "\\", with: "/")
        clean = clean.pocketReplacingMatches(pattern: "^/?(wiki|docs|pages)/", with: "", options: [.caseInsensitive])
        clean = removeWikiExtension(clean)
        return clean
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { slugify(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    static func baseName(_ path: String) -> String {
        let clean = path.replacingOccurrences(of: "\\", with: "/")
        let last = clean.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? clean
        return removeWikiExtension(last)
    }

    static func removeWikiExtension(_ value: String) -> String {
        value
            .pocketReplacingMatches(pattern: "\\.excalidraw\\.md$", with: "", options: [.caseInsensitive])
            .pocketReplacingMatches(pattern: "\\.excalidraw$", with: "", options: [.caseInsensitive])
            .pocketReplacingMatches(pattern: "\\.md$", with: "", options: [.caseInsensitive])
    }

    static func parseFrontmatter(_ content: String) -> [String: String] {
        guard content.hasPrefix("---") else { return [:] }
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.pocketTrimmed == "---" else { return [:] }

        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.pocketTrimmed == "---" { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).pocketTrimmed.lowercased()
            var value = String(line[line.index(after: separator)...]).pocketTrimmed
            value = value.pocketReplacingMatches(pattern: "^['\"]|['\"]$", with: "")
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }

    static func stripFrontmatter(_ content: String) -> String {
        content.pocketReplacingMatches(pattern: "^---\\s*\\n[\\s\\S]*?\\n---\\s*", with: "")
    }

    static func title(from content: String, fallback: String) -> String {
        let frontmatter = parseFrontmatter(content)
        if let title = frontmatter["title"]?.pocketTrimmed, !title.isEmpty {
            return title
        }

        for match in content.pocketMatches(pattern: "^#\\s+(.+)$", options: [.anchorsMatchLines]) {
            guard match.numberOfRanges > 1 else { continue }
            let title = content.pocketSubstring(match.range(at: 1))
                .pocketReplacingMatches(pattern: "[#*_`]", with: "")
                .pocketTrimmed
            if !title.isEmpty { return title }
        }

        return fallback
    }

    static func extractTags(_ content: String) -> [String] {
        let noCode = content.pocketReplacingMatches(pattern: "```[\\s\\S]*?```", with: " ")
        var tags: [String] = []
        var seen = Set<String>()

        for match in noCode.pocketMatches(pattern: "(^|\\s)#([\\p{L}\\p{N}_/-]{2,})", options: [.anchorsMatchLines]) {
            guard match.numberOfRanges > 2 else { continue }
            let tag = noCode.pocketSubstring(match.range(at: 2)).lowercased()
            if seen.insert(tag).inserted {
                tags.append(tag)
            }
        }

        return tags
    }

    static func extractHeadings(_ content: String) -> [WikiHeading] {
        let body = stripFrontmatter(content)
        return body.pocketMatches(pattern: "^(#{1,4})\\s+(.+)$", options: [.anchorsMatchLines]).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let marker = body.pocketSubstring(match.range(at: 1))
            let text = body.pocketSubstring(match.range(at: 2))
                .pocketReplacingMatches(pattern: "[#*_`]", with: "")
                .pocketTrimmed
            guard !text.isEmpty else { return nil }
            return WikiHeading(id: slugify(text), level: marker.count, text: text)
        }
    }

    static func extractSummary(_ content: String) -> String {
        let frontmatter = parseFrontmatter(content)
        if let summary = (frontmatter["summary"] ?? frontmatter["description"])?.pocketTrimmed, !summary.isEmpty {
            return summary
        }

        let summaryPatterns = [
            "\\*\\*Summary\\*\\*\\s*:?\\s*(.+)",
            "\\*\\*Resumo\\*\\*\\s*:?\\s*(.+)"
        ]
        for pattern in summaryPatterns {
            if let match = content.pocketMatches(pattern: pattern, options: [.caseInsensitive]).first, match.numberOfRanges > 1 {
                return content.pocketSubstring(match.range(at: 1)).pocketTrimmed
            }
        }

        let body = stripFrontmatter(content)
            .pocketReplacingMatches(pattern: "```[\\s\\S]*?```", with: " ")
            .components(separatedBy: .newlines)
            .map(\.pocketTrimmed)
            .first { line in
                !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("|") && !line.hasPrefix("---")
            } ?? ""

        return body
            .pocketReplacingMatches(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]", with: "$2$1")
            .pocketReplacingMatches(pattern: "[*_`>]", with: "")
            .pocketTruncated(to: 180)
    }

    static func extractUpdated(_ content: String, lastModified: Date?) -> Date? {
        let frontmatter = parseFrontmatter(content)
        var candidates = [frontmatter["updated"], frontmatter["modified"], frontmatter["date"], frontmatter["created"]].compactMap(\.self)

        if let match = content.pocketMatches(pattern: "\\*\\*(Last updated|Atualizado|Data)\\*\\*\\s*:?\\s*(.+)", options: [.caseInsensitive]).first,
           match.numberOfRanges > 2 {
            candidates.insert(content.pocketSubstring(match.range(at: 2)), at: 0)
        }

        for candidate in candidates {
            if let date = PocketWikiDateParser.parse(candidate) {
                return date
            }
        }

        return lastModified
    }

    static func extractWikiLinks(_ content: String) -> [WikiLink] {
        var links: [WikiLink] = []

        for match in content.pocketMatches(pattern: "\\[\\[([^\\]]+)\\]\\]") {
            guard match.numberOfRanges > 1 else { continue }
            let raw = content.pocketSubstring(match.range(at: 1)).pocketTrimmed
            let parts = raw.split(separator: "|", maxSplits: 1).map { String($0).pocketTrimmed }
            let targetRaw = parts.first ?? raw
            let alias = parts.count > 1 ? parts[1] : nil
            let targetParts = targetRaw.split(separator: "#", maxSplits: 1).map(String.init)
            let target = targetParts.first?.pocketTrimmed ?? ""
            let heading = targetParts.count > 1 ? targetParts[1].pocketTrimmed : ""
            let label = alias?.isEmpty == false ? alias! : targetRaw

            if !target.isEmpty {
                links.append(WikiLink(raw: raw, targetRaw: targetRaw, target: target, heading: heading, label: label))
            }
        }

        return uniqueWikiLinks(links)
    }

    static func uniqueWikiLinks(_ links: [WikiLink]) -> [WikiLink] {
        var seen = Set<String>()
        return links.filter { link in
            seen.insert(link.id).inserted
        }
    }

    static func wordCount(_ content: String) -> Int {
        let body = stripFrontmatter(content)
            .pocketReplacingMatches(pattern: "```[\\s\\S]*?```", with: " ")
            .pocketReplacingMatches(pattern: "[#*_`\\[\\]()>|:-]", with: " ")

        return body.pocketMatches(pattern: "[\\p{L}\\p{N}]+").count
    }

    static func sanitizedMarkdownForDisplay(_ content: String) -> String {
        stripFrontmatter(content)
            .pocketReplacingMatches(pattern: "<script[\\s\\S]*?</script>", with: "", options: [.caseInsensitive])
            .pocketReplacingMatches(pattern: "<iframe[\\s\\S]*?</iframe>", with: "", options: [.caseInsensitive])
            .pocketReplacingMatches(pattern: "<object[\\s\\S]*?</object>", with: "", options: [.caseInsensitive])
            .pocketReplacingMatches(pattern: "<embed[\\s\\S]*?</embed>", with: "", options: [.caseInsensitive])
    }
}
