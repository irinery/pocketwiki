import Foundation

enum WikiMarkdownFormatter {
    static func markdownForDisplay(page: WikiPage, index: WikiIndex) -> String {
        let clean = WikiTextParser.sanitizedMarkdownForDisplay(page.content)
        return replaceWikiLinks(in: clean, index: index)
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
