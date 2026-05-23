import Foundation

enum ExcalidrawParser {
    static func summary(file: WikiFile) -> ExcalidrawSummary {
        let slug = WikiTextParser.pathToSlug(file.relativePath)
        let title = WikiTextParser.title(from: file.content, fallback: file.name)

        if let parsed = parseScene(content: file.content, slug: slug, path: file.relativePath, title: title) {
            return parsed
        }

        let texts = extractMarkdownFallbackTexts(file.content)
        let links = WikiTextParser.extractWikiLinks(texts.joined(separator: "\n"))
        let relations = inferRelationHints(texts)

        return ExcalidrawSummary(
            id: slug,
            slug: slug,
            path: file.relativePath,
            title: title,
            texts: texts,
            links: links,
            relationHints: relations,
            stats: .init(elements: texts.count, textElements: texts.count, links: links.count),
            fallbackReason: texts.isEmpty ? "sem texto extraivel" : "fallback textual"
        )
    }

    static func indexMarkdown(summary: ExcalidrawSummary) -> String {
        var lines = [
            "# \(summary.title)",
            "",
            "**Resumo**: Indice textual extraido de arquivo Excalidraw.",
            "",
            "Path: \(summary.path)",
            "",
            "## Textos"
        ]

        if summary.texts.isEmpty {
            lines.append("- sem texto extraido")
        } else {
            lines.append(contentsOf: summary.texts.map { "- \($0)" })
        }

        if !summary.relationHints.isEmpty {
            lines.append("")
            lines.append("## Relacoes")
            lines.append(contentsOf: summary.relationHints.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    private static func parseScene(content: String, slug: String, path: String, title: String) -> ExcalidrawSummary? {
        for candidate in jsonCandidates(content) {
            guard
                let data = candidate.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let elements = object["elements"] as? [[String: Any]]
            else {
                continue
            }

            let texts = elements.compactMap { element -> String? in
                guard (element["type"] as? String) == "text" else { return nil }
                let value = (element["rawText"] as? String) ?? (element["text"] as? String) ?? ""
                let clean = cleanText(value)
                return clean.isEmpty ? nil : clean
            }

            let joined = texts.joined(separator: "\n")
            let links = WikiTextParser.extractWikiLinks(joined)

            return ExcalidrawSummary(
                id: slug,
                slug: slug,
                path: path,
                title: titleFromTexts(title: title, texts: texts),
                texts: texts,
                links: links,
                relationHints: inferRelationHints(texts),
                stats: .init(elements: elements.count, textElements: texts.count, links: links.count),
                fallbackReason: nil
            )
        }

        return nil
    }

    private static func jsonCandidates(_ content: String) -> [String] {
        var candidates = [content.pocketTrimmed]

        for match in content.pocketMatches(pattern: "```(?:json|excalidraw)?\\s*\\n([\\s\\S]*?)```", options: [.caseInsensitive]) {
            guard match.numberOfRanges > 1 else { continue }
            candidates.append(content.pocketSubstring(match.range(at: 1)).pocketTrimmed)
        }

        if let object = balancedJSONObject(in: content) {
            candidates.append(object)
        }

        return candidates.filter { !$0.isEmpty }
    }

    private static func balancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaping = false

        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaping {
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    static func extractMarkdownFallbackTexts(_ content: String) -> [String] {
        let body = WikiTextParser.stripFrontmatter(content)
            .pocketReplacingMatches(pattern: "```[\\s\\S]*?```", with: " ")

        var values: [String] = []
        var seen = Set<String>()

        for rawLine in body.components(separatedBy: .newlines) {
            let line = cleanText(rawLine)
            guard line.count >= 2 else { continue }
            guard !line.hasPrefix("{"), !line.hasPrefix("}"), !line.hasPrefix("\"") else { continue }
            guard !line.lowercased().contains("compressed-json") else { continue }
            guard seen.insert(line).inserted else { continue }
            values.append(line)
        }

        return values
    }

    private static func inferRelationHints(_ texts: [String]) -> [String] {
        texts.filter { text in
            text.contains("->") || text.contains("→") || text.contains("=>")
        }
    }

    private static func cleanText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .pocketReplacingMatches(pattern: "[#*_`]", with: "")
            .pocketReplacingMatches(pattern: "\\s+", with: " ")
            .pocketTrimmed
    }

    private static func titleFromTexts(title: String, texts: [String]) -> String {
        guard title.isEmpty || title == "Untitled" else { return title }
        return texts.first?.pocketTruncated(to: 90) ?? title
    }
}
