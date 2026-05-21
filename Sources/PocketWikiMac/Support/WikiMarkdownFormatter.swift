import Foundation

enum WikiMarkdownFormatter {
    static func markdownForDisplay(page: WikiPage, index: WikiIndex) -> String {
        let clean = stripDuplicateTitleHeading(
            WikiTextParser.sanitizedMarkdownForDisplay(page.content),
            pageTitle: page.title
        )
        return replaceWikiLinks(in: clean, index: index)
    }

    static func stripDuplicateTitleHeading(_ markdown: String, pageTitle: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        while lines.first?.pocketTrimmed.isEmpty == true {
            lines.removeFirst()
        }

        guard let first = lines.first?.pocketTrimmed else { return markdown }
        guard let match = first.pocketMatches(pattern: "^#\\s+(.+)$").first, match.numberOfRanges > 1 else {
            return markdown
        }

        let heading = first.pocketSubstring(match.range(at: 1))
            .pocketReplacingMatches(pattern: "[#*_`]", with: "")
            .pocketTrimmed
        let normalizedHeading = WikiTextParser.slugify(heading)
        let normalizedTitle = WikiTextParser.slugify(pageTitle)

        guard normalizedHeading == normalizedTitle else { return markdown }
        lines.removeFirst()
        while lines.first?.pocketTrimmed.isEmpty == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private static func replaceWikiLinks(in markdown: String, index: WikiIndex) -> String {
        var output = markdown
        let matches = markdown.pocketMatches(pattern: "\\[\\[([^\\]]+)\\]\\]").reversed()

        for match in matches {
            guard match.numberOfRanges > 1, let fullRange = Range(match.range(at: 0), in: output) else { continue }
            let raw = markdown.pocketSubstring(match.range(at: 1)).pocketTrimmed
            let parts = raw.split(separator: "|", maxSplits: 1).map { String($0).pocketTrimmed }
            let targetRaw = parts.first ?? raw
            let label = parts.count > 1 ? parts[1] : targetRaw
            let target = targetRaw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? targetRaw
            let targetSlug = WikiTextParser.pathToSlug(target)
            let resolvedID = index.pageByID[targetSlug]?.id ?? resolveAlias(target, index: index)

            let replacement: String
            if let resolvedID, let encoded = resolvedID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                replacement = "[\(label)](pocketwiki://page/\(encoded))"
            } else {
                replacement = "**\(label)**"
            }

            output.replaceSubrange(fullRange, with: replacement)
        }

        return output
    }

    private static func resolveAlias(_ target: String, index: WikiIndex) -> String? {
        let alias = WikiTextParser.slugify(target)
        let matches = index.pages.filter { page in
            WikiTextParser.slugify(page.title) == alias
                || WikiTextParser.slugify(WikiTextParser.baseName(page.path)) == alias
                || page.slug == alias
                || page.slug.hasSuffix("/\(alias)")
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}
