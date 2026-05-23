import Foundation

struct WikiIndexer: Sendable {
    func buildIndex(files: [WikiFile], sourceName: String, loadIssues: [String] = []) -> WikiIndex {
        var pages = files.map(makePage)
        var aliasIndex: [String: String] = [:]

        for page in pages {
            let fileAlias = WikiTextParser.slugify(WikiTextParser.baseName(page.path))
            let titleAlias = WikiTextParser.slugify(page.title)
            aliasIndex[page.slug] = page.id
            if aliasIndex[fileAlias] == nil { aliasIndex[fileAlias] = page.id }
            if aliasIndex[titleAlias] == nil { aliasIndex[titleAlias] = page.id }
        }

        for index in pages.indices {
            pages[index].outlinks = []
            pages[index].backlinks = []
            pages[index].missingLinks = []
        }

        var missingLinks: [String: Set<String>] = [:]
        var pageByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })

        for sourceIndex in pages.indices {
            for link in pages[sourceIndex].links {
                if let resolved = resolve(link.target, aliasIndex: aliasIndex, pages: pageByID) {
                    let resolvedLink = WikiResolvedLink(link: link, resolvedPageID: resolved)
                    pages[sourceIndex].outlinks.append(resolvedLink)
                    pageByID[pages[sourceIndex].id]?.outlinks.append(resolvedLink)

                    if let destinationIndex = pages.firstIndex(where: { $0.id == resolved }) {
                        pages[destinationIndex].backlinks.append(pages[sourceIndex].id)
                        pageByID[resolved]?.backlinks.append(pages[sourceIndex].id)
                    }
                } else {
                    pages[sourceIndex].missingLinks.append(link)
                    pageByID[pages[sourceIndex].id]?.missingLinks.append(link)
                    let key = WikiTextParser.slugify(link.target)
                    missingLinks[key, default: []].insert(pages[sourceIndex].id)
                }
            }
        }

        var tagIndex: [String: Set<String>] = [:]
        for page in pages {
            for tag in page.tags {
                tagIndex[tag, default: []].insert(page.id)
            }
        }

        return WikiIndex(
            sourceName: sourceName,
            pages: pages,
            missingLinks: missingLinks.mapValues { Array($0).sorted() },
            tagIndex: tagIndex.mapValues { Array($0).sorted() },
            loadIssues: loadIssues
        )
    }

    private func makePage(file: WikiFile) -> WikiPage {
        switch file.kind {
        case .markdown:
            return makeMarkdownPage(file: file)
        case .excalidraw, .excalidrawMarkdown:
            let summary = ExcalidrawParser.summary(file: file)
            let content = ExcalidrawParser.indexMarkdown(summary: summary)
            return makeMarkdownPage(file: file, contentOverride: content, kind: .excalidraw, summary: summary)
        }
    }

    private func makeMarkdownPage(file: WikiFile, contentOverride: String? = nil, kind: WikiPage.Kind = .markdown, summary: ExcalidrawSummary? = nil) -> WikiPage {
        let content = contentOverride ?? file.content
        let slug = WikiTextParser.pathToSlug(file.relativePath)
        let title = summary?.title ?? WikiTextParser.title(from: content, fallback: file.name)
        let links = WikiTextParser.extractWikiLinks(content)
        let words = WikiTextParser.wordCount(content)
        let folder = file.relativePath.contains("/")
            ? file.relativePath.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
            : ""

        return WikiPage(
            id: slug,
            slug: slug,
            path: file.relativePath,
            title: title,
            folder: folder,
            content: content,
            summary: WikiTextParser.extractSummary(content),
            tags: WikiTextParser.extractTags(content),
            links: links,
            outlinks: [],
            backlinks: [],
            missingLinks: [],
            headings: WikiTextParser.extractHeadings(content),
            updatedAt: WikiTextParser.extractUpdated(content, lastModified: file.modifiedAt),
            wordCount: words,
            readingMinutes: max(1, Int(ceil(Double(words) / 210.0))),
            isSpecial: isSpecial(slug),
            sizeBytes: file.sizeBytes,
            kind: kind,
            excalidraw: summary
        )
    }

    private func resolve(_ target: String, aliasIndex: [String: String], pages: [String: WikiPage]) -> String? {
        let direct = WikiTextParser.pathToSlug(target)
        if pages[direct] != nil { return direct }

        let alias = WikiTextParser.slugify(target)
        if let resolved = aliasIndex[alias] { return resolved }

        let suffixMatches = pages.keys.filter { $0 == alias || $0.hasSuffix("/\(alias)") }
        return suffixMatches.count == 1 ? suffixMatches[0] : nil
    }

    private func isSpecial(_ slug: String) -> Bool {
        let last = slug.split(separator: "/").last.map(String.init) ?? slug
        return ["index", "home", "readme", "log", "changelog"].contains(last.lowercased())
    }
}
