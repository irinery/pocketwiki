import Foundation

enum WikiAnalytics {
    static func metrics(for index: WikiIndex) -> WikiDashboardMetrics {
        let links = index.pages.reduce(0) { partial, page in
            partial + page.outlinks.count + page.missingLinks.count
        }
        let drawings = index.pages.filter { $0.kind == .excalidraw }.count

        return WikiDashboardMetrics(
            pages: index.pages.count,
            links: links,
            drawings: drawings,
            missingDestinations: index.missingLinks.count,
            healthScore: healthScore(for: index)
        )
    }

    static func healthScore(for index: WikiIndex) -> Int {
        let orphans = orphanPages(in: index).count
        let noSummary = index.pages.filter { $0.summary.isEmpty }.count
        let isolated = isolatedPages(in: index).count
        let score = 100 - index.missingLinks.count * 5 - orphans * 2 - noSummary - isolated * 3
        return min(100, max(0, score))
    }

    static func healthIssues(for index: WikiIndex, now: Date = Date()) -> [WikiHealthIssue] {
        let missingSources = index.pages.filter { !$0.missingLinks.isEmpty }.sorted { $0.missingLinks.count > $1.missingLinks.count }
        let isolated = isolatedPages(in: index)
        let orphans = orphanPages(in: index)
        let noSummary = index.pages.filter { $0.summary.isEmpty }
        let stale = stalePages(in: index, now: now)
        let tagless = index.pages.filter { $0.tags.isEmpty && !$0.isSpecial }

        var issues: [WikiHealthIssue] = []

        if !missingSources.isEmpty {
            issues.append(.init(
                id: "missing-links",
                priority: .high,
                title: "Corrigir links quebrados primeiro",
                detail: "\(index.missingLinks.count) destino(s) ausente(s). Priorize paginas com mais referencias.",
                pageIDs: missingSources.prefix(6).map(\.id)
            ))
        }

        if !isolated.isEmpty {
            issues.append(.init(
                id: "isolated",
                priority: .high,
                title: "Conectar paginas isoladas",
                detail: "\(isolated.count) pagina(s) nao recebem nem apontam links.",
                pageIDs: isolated.prefix(6).map(\.id)
            ))
        }

        if !orphans.isEmpty {
            issues.append(.init(
                id: "orphans",
                priority: .medium,
                title: "Dar entrada para paginas orfas",
                detail: "\(orphans.count) pagina(s) sem backlinks.",
                pageIDs: orphans.prefix(6).map(\.id)
            ))
        }

        if !noSummary.isEmpty {
            issues.append(.init(
                id: "no-summary",
                priority: .medium,
                title: "Adicionar resumos operacionais",
                detail: "\(noSummary.count) pagina(s) sem resumo detectado.",
                pageIDs: noSummary.prefix(6).map(\.id)
            ))
        }

        if !stale.isEmpty {
            issues.append(.init(
                id: "stale",
                priority: .low,
                title: "Revalidar conteudo antigo",
                detail: "\(stale.count) pagina(s) tem data detectada maior que 180 dias.",
                pageIDs: stale.prefix(6).map(\.id)
            ))
        }

        if !tagless.isEmpty {
            issues.append(.init(
                id: "tagless",
                priority: .low,
                title: "Normalizar tags nos clusters",
                detail: "\(tagless.count) pagina(s) sem tags.",
                pageIDs: tagless.prefix(6).map(\.id)
            ))
        }

        return issues.sorted {
            if $0.priority.sortOrder == $1.priority.sortOrder { return $0.title < $1.title }
            return $0.priority.sortOrder < $1.priority.sortOrder
        }
    }

    static func orphanPages(in index: WikiIndex) -> [WikiPage] {
        index.pages.filter { !$0.isSpecial && $0.backlinks.isEmpty }
    }

    static func isolatedPages(in index: WikiIndex) -> [WikiPage] {
        index.pages.filter { !$0.isSpecial && $0.backlinks.isEmpty && $0.outlinks.isEmpty }
    }

    static func stalePages(in index: WikiIndex, now: Date = Date()) -> [WikiPage] {
        let maxAge = TimeInterval(180 * 24 * 60 * 60)
        return index.pages
            .filter { page in
                guard let updatedAt = page.updatedAt else { return false }
                return now.timeIntervalSince(updatedAt) > maxAge
            }
            .sorted { ($0.updatedAt ?? .distantFuture) < ($1.updatedAt ?? .distantFuture) }
    }

    static func timelinePages(in index: WikiIndex) -> [WikiPage] {
        index.pages.sorted { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }
}
