import Foundation

struct WikiSidebarSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [WikiSidebarItem]
}

struct WikiSidebarItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case page(String)
        case tag(String)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let icon: String
    let isWarning: Bool
}

enum WikiSidebarExplorer {
    static func sections(index: WikiIndex, selectedPageID: String?, query: String) -> [WikiSidebarSection] {
        guard !index.pages.isEmpty else { return [] }

        let cleanQuery = query.pocketTrimmed.lowercased()
        if !cleanQuery.isEmpty {
            return [
                WikiSidebarSection(
                    id: "search",
                    title: "Busca",
                    items: searchPages(index.pages, query: cleanQuery).prefixItems(24, reason: "resultado")
                )
            ]
        }

        var sections: [WikiSidebarSection] = []

        if let selected = index.page(id: selectedPageID) {
            sections.append(WikiSidebarSection(
                id: "current",
                title: "Atual",
                items: [item(for: selected, reason: selected.folder.isEmpty ? selected.path : selected.folder)]
            ))

            let relatedIDs = stableUnique(selected.backlinks + selected.outlinks.compactMap(\.resolvedPageID))
            let related = relatedIDs.compactMap { index.page(id: $0) }
            if !related.isEmpty {
                sections.append(WikiSidebarSection(
                    id: "related",
                    title: "Relacionadas",
                    items: related.prefixItems(10, reason: "link direto")
                ))
            }
        }

        let hubs = index.pages.sorted { $0.connectivityScore > $1.connectivityScore }.prefix(6)
        let recent = WikiAnalytics.timelinePages(in: index).prefix(6)
        let review = index.pages
            .filter { !$0.missingLinks.isEmpty || $0.healthClass != .good }
            .sorted { $0.missingLinks.count > $1.missingLinks.count }
            .prefix(6)

        let exploreItems = stableUniquePages(Array(hubs) + Array(recent) + Array(review))
            .prefixItems(14) { page in
                if !page.missingLinks.isEmpty { return "\(page.missingLinks.count) link(s) ausente(s)" }
                if page.connectivityScore >= 4 { return "hub da wiki" }
                if page.updatedAt != nil { return "recente" }
                return page.folder.isEmpty ? page.path : page.folder
            }

        if !exploreItems.isEmpty {
            sections.append(WikiSidebarSection(id: "explore", title: "Explorar", items: exploreItems))
        }

        let tags = index.tagIndex
            .sorted { lhs, rhs in
                if lhs.value.count == rhs.value.count { return lhs.key < rhs.key }
                return lhs.value.count > rhs.value.count
            }
            .prefix(12)
            .map { tag, pages in
                WikiSidebarItem(
                    id: "tag:\(tag)",
                    kind: .tag(tag),
                    title: "#\(tag)",
                    detail: "\(pages.count) pagina(s)",
                    icon: "tag",
                    isWarning: false
                )
            }

        if !tags.isEmpty {
            sections.append(WikiSidebarSection(id: "tags", title: "Tags", items: Array(tags)))
        }

        return sections
    }

    static func searchPages(_ pages: [WikiPage], query: String) -> [WikiPage] {
        pages.filter { page in
            page.title.lowercased().contains(query)
                || page.path.lowercased().contains(query)
                || page.summary.lowercased().contains(query)
                || page.tags.contains(where: { $0.lowercased().contains(query.replacingOccurrences(of: "#", with: "")) })
        }
    }

    private static func item(for page: WikiPage, reason: String) -> WikiSidebarItem {
        WikiSidebarItem(
            id: "page:\(page.id)",
            kind: .page(page.id),
            title: page.title,
            detail: reason,
            icon: page.kind == .excalidraw ? "scribble.variable" : page.missingLinks.isEmpty ? "doc.text" : "exclamationmark.triangle",
            isWarning: !page.missingLinks.isEmpty
        )
    }

    private static func stableUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func stableUniquePages(_ pages: [WikiPage]) -> [WikiPage] {
        var seen = Set<String>()
        return pages.filter { seen.insert($0.id).inserted }
    }
}

private extension Sequence where Element == WikiPage {
    func prefixItems(_ limit: Int, reason: String) -> [WikiSidebarItem] {
        prefix(limit).map { page in
            WikiSidebarItem(
                id: "page:\(page.id)",
                kind: .page(page.id),
                title: page.title,
                detail: reason,
                icon: page.kind == .excalidraw ? "scribble.variable" : page.missingLinks.isEmpty ? "doc.text" : "exclamationmark.triangle",
                isWarning: !page.missingLinks.isEmpty
            )
        }
    }

    func prefixItems(_ limit: Int, reason: (WikiPage) -> String) -> [WikiSidebarItem] {
        prefix(limit).map { page in
            WikiSidebarItem(
                id: "page:\(page.id)",
                kind: .page(page.id),
                title: page.title,
                detail: reason(page),
                icon: page.kind == .excalidraw ? "scribble.variable" : page.missingLinks.isEmpty ? "doc.text" : "exclamationmark.triangle",
                isWarning: !page.missingLinks.isEmpty
            )
        }
    }
}
