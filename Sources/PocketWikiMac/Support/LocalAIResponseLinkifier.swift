import Foundation

enum LocalAIResponseLinkifier {
    private static let pathPattern = #"(?i)(\*\*Path:\*\*\s*|Path:\s*)(`?)([^`\s,;\)\]]+\.(?:md|excalidraw(?:\.md)?))(`?)"#

    static func linkify(_ markdown: String, index: WikiIndex) -> String {
        guard !markdown.isEmpty,
              let regex = try? NSRegularExpression(pattern: pathPattern) else {
            return markdown
        }

        let pathMap = Dictionary(uniqueKeysWithValues: index.pages.map { ($0.path.lowercased(), $0.id) })
        guard !pathMap.isEmpty else { return markdown }

        let nsRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var output = markdown
        for match in regex.matches(in: markdown, range: nsRange).reversed() {
            guard match.numberOfRanges >= 4,
                  let fullRange = Range(match.range(at: 0), in: markdown),
                  let prefixRange = Range(match.range(at: 1), in: markdown),
                  let pathRange = Range(match.range(at: 3), in: markdown) else {
                continue
            }

            let prefix = String(markdown[prefixRange])
            let path = String(markdown[pathRange])
            guard let pageID = pathMap[path.lowercased()],
                  let encoded = pageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                continue
            }

            output.replaceSubrange(fullRange, with: "\(prefix)[\(path)](pocketwiki://page/\(encoded))")
        }
        return output
    }
}
