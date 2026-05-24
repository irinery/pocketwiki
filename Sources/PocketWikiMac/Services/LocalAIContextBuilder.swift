import Foundation

enum LocalAIContextBuilder {
    private static let stopWords = Set(
        "a o os as um uma uns umas de da do das dos e em no na nos nas por para com sem sobre entre que qual quais como quando onde porque pra pro ao aos ou se sua seu suas seus meu minha meus minhas isso esse essa estes estas aquele aquela trazer traga mostre mostra mostrar quero preciso pode poderia pagina página wiki arquivo arquivos ajuda ajudar favor favorzinho explica explique falar fale diz diga"
            .split(separator: " ")
            .map(String.init)
    )

    private static let shortTerms = Set("ai ia ip db ui vm ci cd dns tls ssh vpn nas wan lan iot idp sso api sql pwa".split(separator: " ").map(String.init))

    private static let aliases: [String: [String]] = [
        "auth": ["autenticacao", "autorizacao", "login", "sso", "oauth", "oidc", "keycloak", "token", "sessao", "senha"],
        "autenticacao": ["auth", "login", "sso", "oauth", "oidc", "keycloak", "token", "sessao", "senha"],
        "login": ["auth", "autenticacao", "sso", "oauth", "oidc", "keycloak", "senha", "usuario"],
        "rede": ["network", "lan", "wan", "vlan", "wifi", "dns", "dhcp", "roteador", "mikrotik"],
        "network": ["rede", "lan", "wan", "vlan", "wifi", "dns", "dhcp", "router", "mikrotik"],
        "monitoramento": ["zabbix", "grafana", "alerta", "metricas", "observabilidade", "dashboard"],
        "servidor": ["server", "host", "maquina", "vm", "node"],
        "docker": ["container", "compose", "pod"],
        "kubernetes": ["k8s", "k3s", "cluster", "pod", "deployment"],
        "banco": ["database", "db", "postgres", "postgresql", "sql"],
        "camera": ["câmera", "scrypted", "homekit", "hksv", "stream", "rtsp"],
        "backup": ["restore", "snapshot", "copia", "export", "dump"],
        "desenho": ["diagrama", "excalidraw", "fluxo", "mapa"],
        "ia": ["ai", "llm", "modelo", "lm-studio", "lmstudio"],
        "ai": ["ia", "llm", "modelo", "lm-studio", "lmstudio"],
        "llm": ["ia", "ai", "modelo", "lm-studio", "lmstudio"]
    ]

    static func build(
        index: WikiIndex,
        selectedPageID: String?,
        scope: LocalAIContextScope,
        maxCharacters: Int,
        question: String = "",
        manualSources: [LocalAIManualContextSource] = [],
        excludedPaths: Set<String> = []
    ) -> LocalAIContextPayload {
        if scope == .automatic {
            let context = buildAutomatic(
                question: question,
                index: index,
                selectedPageID: selectedPageID,
                maxCharacters: maxCharacters,
                excludedPaths: excludedPaths
            )
            return addingManualSources(manualSources, to: context, maxCharacters: maxCharacters)
        }

        let limit = max(1_500, maxCharacters)
        let pages = pagesForScope(index: index, selectedPageID: selectedPageID, scope: scope)
            .filter { !excludedPaths.contains($0.path) }
        let body: String

        switch scope {
        case .automatic:
            body = ""
        case .currentPage:
            body = renderFullPageContext(pages.first, index: index)
        case .linkedPages:
            body = renderFullLinkedContext(pages, index: index)
        case .wikiDigest:
            body = renderWikiDigest(index)
        }

        let fitted = fit(body, maxCharacters: limit)
        let context = LocalAIContextPayload(
            mode: .wiki,
            title: scope.title,
            body: fitted,
            includedPaths: pages.map(\.path),
            manualPaths: [],
            characters: fitted.count,
            notice: nil
        )
        return addingManualSources(manualSources, to: context, maxCharacters: maxCharacters)
    }

    static func buildAutomatic(
        question: String,
        index: WikiIndex,
        selectedPageID: String?,
        maxCharacters: Int,
        excludedPaths: Set<String> = []
    ) -> LocalAIContextPayload {
        let cleanQuestion = singleLine(question)
        let scope = classify(cleanQuestion)
        guard scope.maxPages > 0 else {
            return LocalAIContextPayload(
                mode: .general,
                title: "Geral",
                body: "",
                includedPaths: [],
                manualPaths: [],
                characters: 0,
                notice: index.pages.isEmpty ? "Nenhuma pagina da wiki esta carregada agora." : nil
            )
        }
        guard !index.pages.isEmpty else {
            return LocalAIContextPayload(
                mode: .general,
                title: "Geral",
                body: "",
                includedPaths: [],
                manualPaths: [],
                characters: 0,
                notice: "Nenhuma pagina da wiki esta carregada agora."
            )
        }

        let terms = searchTerms(cleanQuestion)
        let current = index.page(id: selectedPageID)
        let candidates = index.pages
            .map { (page: $0, score: score(page: $0, terms: terms, current: current)) }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.page.connectivityScore > rhs.page.connectivityScore
                }
                return lhs.score > rhs.score
            }
            .prefix(scope.indexItems)

        let indexSnapshot = groundingIndexSnapshot(index, maxCharacters: min(2_200, max(900, maxCharacters / 5)))
        let selected = highConfidenceSelection(Array(candidates), maxPages: scope.maxPages)
            .filter { !excludedPaths.contains($0.path) }
        guard !selected.isEmpty else {
            let indexText = compactIndexResults(Array(candidates), maxCharacters: scope.indexBudget)
            let body = """
            Interpretacao da pergunta:
            \(cleanQuestion)

            Busca no indice:
            \(terms.prefix(12).map { "- \($0)" }.joined(separator: "\n"))

            Indice base da wiki:
            \(indexSnapshot)

            Resultado do indice:
            \(indexText)

            Paginas consultadas:
            Nenhuma pagina passou no corte de relevancia. Nao use conhecimento externo para preencher a lacuna.
            """
            let fitted = fit(body, maxCharacters: maxCharacters)
            return LocalAIContextPayload(
                mode: .wiki,
                title: "Auto",
                body: fitted,
                includedPaths: [],
                manualPaths: [],
                characters: fitted.count,
                notice: "Indice consultado, mas nenhuma pagina passou no corte de relevancia."
            )
        }

        let indexText = compactIndexResults(Array(candidates), maxCharacters: scope.indexBudget)
        let pageBudget = max(1_200, maxCharacters - indexText.count)
        let blocks = selected.enumerated().map { _, page in
            compactPage(page, terms: terms, maxCharacters: max(900, pageBudget / max(1, selected.count)))
        }
        let body = """
        Interpretacao da pergunta:
        \(cleanQuestion)

        Busca no indice:
        \(terms.prefix(12).map { "- \($0)" }.joined(separator: "\n"))

        Indice base da wiki:
        \(indexSnapshot)

        Resultado do indice:
        \(indexText)

        Paginas consultadas:

        \(blocks.joined(separator: "\n\n---\n\n"))
        """
        let fitted = fit(body, maxCharacters: maxCharacters)
        return LocalAIContextPayload(
            mode: .wiki,
            title: "Auto",
            body: fitted,
            includedPaths: selected.map(\.path),
            manualPaths: [],
            characters: fitted.count,
            notice: nil
        )
    }

    static func addingManualSources(
        _ sources: [LocalAIManualContextSource],
        to context: LocalAIContextPayload,
        maxCharacters: Int
    ) -> LocalAIContextPayload {
        guard !sources.isEmpty else { return context }

        let manualBody = sources.map { source in
            """
            # \(source.title)
            Path: \(source.path)

            \(source.content)
            """
        }
        .joined(separator: "\n\n---\n\n")

        let body = context.body.isEmpty
            ? "Contexto adicionado manualmente:\n\n\(manualBody)"
            : "\(context.body)\n\n---\n\nContexto adicionado manualmente:\n\n\(manualBody)"
        let fitted = fit(body, maxCharacters: maxCharacters)
        let manualPaths = sources.map(\.path)
        return LocalAIContextPayload(
            mode: .wiki,
            title: context.title,
            body: fitted,
            includedPaths: uniqueStrings(context.includedPaths + manualPaths),
            manualPaths: manualPaths,
            characters: fitted.count,
            notice: context.notice
        )
    }

    static func systemPrompt(context: LocalAIContextPayload) -> String {
        switch context.mode {
        case .general:
            """
            Voce e o assistente local do PocketWiki.

            Responda como um chatbot normal, em portugues brasileiro informal, direto e curto.
            Nao force consulta a wiki quando a mensagem for conversa comum.
            Use Markdown simples quando ajudar: negrito, italico e listas.
            Nao use tags XML/HTML nem placeholders.
            Se o sistema disser que a wiki nao trouxe resultado, mencione isso em uma frase curta so quando for relevante.
            """
        case .wiki:
            """
            Voce e o assistente local do PocketWiki.

            Voce recebe o resultado de uma consulta seletiva feita pelo PocketWiki.
            O fluxo e: pergunta -> busca no indice -> escolha de paginas -> leitura so das paginas necessarias.
            Sua resposta fica presa ao bloco "Consulta seletiva do PocketWiki".
            O bloco "Indice base da wiki" e parte obrigatoria do contexto: use-o para entender o acervo carregado antes de responder.

            Regras:
            - Responda em portugues brasileiro informal, direto e curto.
            - Use Markdown simples: negrito para rotulos importantes e listas com "-".
            - Nao use conhecimento externo.
            - Nao invente arquivo, path, link ou detalhe que nao esteja na consulta.
            - Para citar fonte, copie exatamente o valor depois de "Path:".
            - Se "Paginas consultadas" disser que nenhuma pagina passou no corte, diga que o indice nao trouxe evidencia suficiente e cite apenas caminhos/tags que aparecam no "Indice base da wiki" ou no "Resultado do indice".
            - Se a relacao for parcial, diga que e parcial e cite os paths relacionados.
            - Se a pergunta pedir lista, entregue lista.
            - Se a pergunta pedir resumo, entregue resumo.
            - Se a pergunta pedir trecho ou parte chave, extraia das paginas consultadas.
            """
        }
    }

    static func userPrompt(question: String, context: LocalAIContextPayload) -> String {
        switch context.mode {
        case .general:
            "\(context.notice.map { "Nota do PocketWiki: \($0)\n\n" } ?? "")\(question)"
        case .wiki:
            """
            Pergunta do usuario:
            \(question)

            Consulta seletiva do PocketWiki:
            \(context.body)

            Responda interpretando somente a consulta acima.
            So diga que nao achou na wiki quando a consulta nao trouxer nenhuma pagina relacionada.
            """
        }
    }

    private static func pagesForScope(index: WikiIndex, selectedPageID: String?, scope: LocalAIContextScope) -> [WikiPage] {
        guard let selected = index.page(id: selectedPageID) ?? index.homePage else {
            return []
        }

        switch scope {
        case .automatic:
            return []
        case .currentPage:
            return [selected]
        case .linkedPages:
            let linkedIDs = selected.outlinks.map(\.resolvedPageID) + selected.backlinks
            let linkedPages = linkedIDs.compactMap { index.page(id: $0) }
            return uniquePages([selected] + linkedPages)
        case .wikiDigest:
            return index.pages
        }
    }

    private static func uniquePages(_ pages: [WikiPage]) -> [WikiPage] {
        var seen = Set<String>()
        return pages.filter { page in
            if seen.contains(page.id) { return false }
            seen.insert(page.id)
            return true
        }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            if seen.contains(value) { return false }
            seen.insert(value)
            return true
        }
    }

    private static func renderFullPageContext(_ page: WikiPage?, index: WikiIndex) -> String {
        guard let page else {
            return "Nenhuma pagina selecionada."
        }

        return """
        # \(page.title)
        Path: \(page.path)
        Tags: \(page.tags.isEmpty ? "sem tags" : page.tags.joined(separator: ", "))
        Backlinks: \(page.backlinks.count)
        Outlinks: \(page.outlinks.count)
        Links ausentes: \(page.missingLinks.map(\.label).joined(separator: ", "))

        \(WikiMarkdownFormatter.markdownForDisplay(page: page, index: index))
        """
    }

    private static func renderFullLinkedContext(_ pages: [WikiPage], index: WikiIndex) -> String {
        guard !pages.isEmpty else {
            return "Nenhuma pagina selecionada."
        }

        return pages.map { page in
            """
            # \(page.title)
            Path: \(page.path)
            Tags: \(page.tags.isEmpty ? "sem tags" : page.tags.joined(separator: ", "))
            Resumo: \(page.summary.isEmpty ? "sem resumo" : page.summary)

            \(WikiMarkdownFormatter.markdownForDisplay(page: page, index: index))
            """
        }
        .joined(separator: "\n\n---\n\n")
    }

    private static func renderWikiDigest(_ index: WikiIndex) -> String {
        let metrics = WikiAnalytics.metrics(for: index)
        let hubs = index.pages.sorted { $0.connectivityScore > $1.connectivityScore }.prefix(12)
        let recent = WikiAnalytics.timelinePages(in: index).prefix(12)
        let broken = index.missingLinks.sorted { $0.value.count > $1.value.count }.prefix(12)

        return """
        # \(index.sourceName)
        Paginas: \(metrics.pages)
        Links: \(metrics.links)
        Desenhos: \(metrics.drawings)
        Destinos ausentes: \(metrics.missingDestinations)
        Score de saude: \(metrics.healthScore)/100

        ## Hubs
        \(hubs.map { "- \($0.title) (\($0.path)): \($0.backlinks.count) backlinks, \($0.outlinks.count) outlinks" }.joined(separator: "\n"))

        ## Recentes
        \(recent.map { "- \($0.title) (\($0.path)): \(PocketFormatters.date($0.updatedAt))" }.joined(separator: "\n"))

        ## Links quebrados frequentes
        \(broken.map { "- \($0.key): \($0.value.count) referencias" }.joined(separator: "\n"))
        """
    }

    private static func groundingIndexSnapshot(_ index: WikiIndex, maxCharacters: Int) -> String {
        let metrics = WikiAnalytics.metrics(for: index)
        let hubs = index.pages.sorted { $0.connectivityScore > $1.connectivityScore }.prefix(8)
        let recent = WikiAnalytics.timelinePages(in: index).prefix(8)
        let tags = index.tagIndex
            .sorted { lhs, rhs in
                if lhs.value.count == rhs.value.count {
                    return lhs.key < rhs.key
                }
                return lhs.value.count > rhs.value.count
            }
            .prefix(10)
            .map { "#\($0.key)(\($0.value.count))" }
            .joined(separator: " ")

        let snapshot = """
        Fonte: \(index.sourceName)
        Paginas indexadas: \(metrics.pages)
        Links: \(metrics.links)
        Desenhos: \(metrics.drawings)
        Destinos ausentes: \(metrics.missingDestinations)
        Tags principais: \(tags.isEmpty ? "sem tags" : tags)

        Hubs:
        \(hubs.map { "- Path: \($0.path) | Titulo: \(singleLine($0.title)) | Tags: \($0.tags.prefix(5).map { "#\($0)" }.joined(separator: " "))" }.joined(separator: "\n"))

        Recentes:
        \(recent.map { "- Path: \($0.path) | Titulo: \(singleLine($0.title)) | Atualizado: \(PocketFormatters.date($0.updatedAt))" }.joined(separator: "\n"))
        """
        return fit(snapshot, maxCharacters: maxCharacters)
    }

    private static func classify(_ question: String) -> (maxPages: Int, indexItems: Int, indexBudget: Int) {
        let folded = fold(question)
        let words = folded.split { !$0.isLetter && !$0.isNumber }
        let terms = questionTerms(question)
        if question.isEmpty { return (0, 0, 0) }
        if ["oi", "ola", "bom dia", "boa tarde", "boa noite", "teste", "ping", "ok", "valeu"].contains(folded) {
            return (0, 0, 0)
        }
        if words.count <= 3 && terms.isEmpty { return (0, 0, 0) }
        if folded.pocketMatches(pattern: "\\b(detalh|profund|compare|comparar|auditor|auditoria|diagnostic|diagnostico|arquitetura|explique|analise|analisar|mapeia|mapear|revisao|plano|passo a passo|inventario|relatorio)\\b").isEmpty == false {
            return (5, 28, 5_200)
        }
        if words.count > 24 || question.count > 140 {
            return (5, 28, 5_200)
        }
        return (3, 18, 3_600)
    }

    private static func searchTerms(_ question: String) -> [String] {
        Array((questionTerms(question) + expandedTerms(questionTerms(question))).prefix(54))
    }

    private static func questionTerms(_ question: String) -> [String] {
        WikiTextParser.slugify(question)
            .split { $0 == "-" || $0 == "_" || $0 == "/" }
            .map(String.init)
            .filter { ($0.count > 2 || shortTerms.contains($0)) && !stopWords.contains($0) }
            .prefix(14)
            .map(\.self)
    }

    private static func expandedTerms(_ terms: [String]) -> [String] {
        var out: [String] = []
        var seen = Set(terms)
        for term in terms {
            for variant in termVariants(term) + (aliases[term] ?? []).map(WikiTextParser.slugify) {
                guard !variant.isEmpty, !stopWords.contains(variant), !seen.contains(variant) else { continue }
                seen.insert(variant)
                out.append(variant)
            }
        }
        return out
    }

    private static func termVariants(_ term: String) -> [String] {
        guard term.count >= 4 else { return [] }
        var variants = Set<String>()
        if term.hasSuffix("oes") { variants.insert(String(term.dropLast(3)) + "ao") }
        if term.hasSuffix("cao") { variants.insert(String(term.dropLast(3)) + "coes") }
        if term.hasSuffix("s") { variants.insert(String(term.dropLast())) }
        if term.hasSuffix("es") { variants.insert(String(term.dropLast(2))) }
        if term.count > 6 { variants.insert(String(term.dropLast())) }
        return variants.filter { $0.count > 2 }
    }

    private static func score(page: WikiPage, terms: [String], current: WikiPage?) -> Double {
        let title = fold(page.title)
        let path = fold(page.path)
        let summary = fold(page.summary)
        let tags = fold(page.tags.joined(separator: " "))
        let headings = fold(page.headings.map(\.text).joined(separator: " "))
        var value = page.connectivityScore * 0.08

        if let current {
            if page.id == current.id { value += 5 }
            if current.outlinks.contains(where: { $0.resolvedPageID == page.id }) { value += 2 }
            if current.backlinks.contains(page.id) { value += 1.5 }
            if !page.folder.isEmpty, page.folder == current.folder { value += 1 }
        }

        for term in terms {
            if title.contains(term) { value += 10 }
            if path.contains(term) { value += 7 }
            if tags.contains(term) { value += 6 }
            if summary.contains(term) { value += 5 }
            if headings.contains(term) { value += 4 }
            value += fuzzyScore(term, fields: [title, path, tags, summary, headings])
        }
        return value
    }

    private static func fuzzyScore(_ term: String, fields: [String]) -> Double {
        guard term.count >= 4 else { return 0 }
        var best = 0.0
        for token in fields.flatMap(tokenize) {
            best = max(best, similarity(term, token))
        }
        if best >= 0.9 { return 5 }
        if best >= 0.76 { return 3 }
        if best >= 0.62 { return 1.5 }
        return 0
    }

    private static func tokenize(_ value: String) -> [String] {
        Array(Set(value.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 || shortTerms.contains($0) }))
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let minCount = min(a.count, b.count)
        let maxCount = max(a.count, b.count)
        if minCount >= 4, (a.hasPrefix(b) || b.hasPrefix(a)) {
            return Double(minCount) / Double(maxCount) >= 0.55 ? 0.86 : 0.68
        }
        let stemA = looseStem(a)
        let stemB = looseStem(b)
        if stemA.count >= 4, stemB.count >= 4, (stemA == stemB || stemA.hasPrefix(stemB) || stemB.hasPrefix(stemA)) {
            return 0.78
        }
        return 0
    }

    private static func looseStem(_ term: String) -> String {
        term.pocketReplacingMatches(pattern: "(acoes|cao|mente|idades|idade|ismo|ista|ores|ora|or|as|os|es|s)$", with: "")
    }

    private static func highConfidenceSelection(_ candidates: [(page: WikiPage, score: Double)], maxPages: Int) -> [WikiPage] {
        guard let best = candidates.first?.score else { return [] }
        let threshold = max(3, best * 0.45)
        return candidates
            .filter { $0.score >= threshold }
            .prefix(min(maxPages, 3))
            .map(\.page)
    }

    private static func compactIndexResults(_ candidates: [(page: WikiPage, score: Double)], maxCharacters: Int) -> String {
        guard !candidates.isEmpty else { return "Nenhuma pagina candidata encontrada no indice." }
        var lines = ["Indice consultado por titulo, path, resumo, tags e headings; conteudo completo ainda nao foi lido nesta etapa."]
        for item in candidates {
            let page = item.page
            let tags = page.tags.prefix(7).map { "#\($0)" }.joined(separator: " ")
            let headings = page.headings.prefix(5).map(\.text).joined(separator: " | ")
            let block = """
            - Path: \(page.path)
              Titulo: \(singleLine(page.title))
              Resumo: \(singleLine(page.summary).prefix(180))
              Tags: \(tags.isEmpty ? "sem tags" : tags)
              Headings: \(headings.isEmpty ? "sem headings" : headings)
            """
            if lines.joined(separator: "\n").count + block.count + 1 > maxCharacters { break }
            lines.append(block)
        }
        return lines.joined(separator: "\n")
    }

    private static func compactPage(_ page: WikiPage, terms: [String], maxCharacters: Int) -> String {
        let headings = page.headings.prefix(8).map { "\(String(repeating: "#", count: min(4, $0.level))) \($0.text)" }.joined(separator: " | ")
        let excerpts = matchingExcerpts(page.content, terms: terms, maxItems: 4, maxLength: 520)
        let fallback = excerpts.isEmpty ? fallbackExcerpts(page.content, maxItems: 4, maxLength: 520) : excerpts
        let block = """
        Path: \(page.path)
        Titulo: \(page.title)
        Resumo: \(page.summary.isEmpty ? "sem resumo" : page.summary)
        Tags: \(page.tags.map { "#\($0)" }.joined(separator: " "))
        Headings: \(headings.isEmpty ? "sem headings" : headings)
        Conteudo consultado:
        \(fallback.isEmpty ? "- sem excertos uteis" : fallback.map { "- \($0)" }.joined(separator: "\n"))
        """
        guard block.count > maxCharacters else { return block }
        return String(block.prefix(max(0, maxCharacters - 3))).pocketTrimmed + "..."
    }

    private static func matchingExcerpts(_ content: String, terms: [String], maxItems: Int, maxLength: Int) -> [String] {
        let text = compactText(content)
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        let folded = fold(text)
        var positions: [String.Index] = []
        for term in terms {
            var range = folded.startIndex..<folded.endIndex
            while positions.count < maxItems * 3, let found = folded.range(of: term, options: [], range: range) {
                positions.append(found.lowerBound)
                range = found.upperBound..<folded.endIndex
            }
        }
        return excerpt(text, at: positions, maxItems: maxItems, maxLength: maxLength)
    }

    private static func fallbackExcerpts(_ content: String, maxItems: Int, maxLength: Int) -> [String] {
        let chunks = WikiTextParser.stripFrontmatter(content)
            .pocketReplacingMatches(pattern: "```[\\s\\S]*?```", with: " ")
            .components(separatedBy: "\n\n")
            .map(compactText)
            .filter { $0.count >= 24 }
        let selected = chunks.prefix(maxItems).map { String($0.prefix(maxLength)) }
        if !selected.isEmpty { return selected }
        let text = compactText(content)
        return text.isEmpty ? [] : [String(text.prefix(maxLength))]
    }

    private static func excerpt(_ text: String, at positions: [String.Index], maxItems: Int, maxLength: Int) -> [String] {
        var excerpts: [String] = []
        for position in positions.prefix(maxItems) {
            let distance = text.distance(from: text.startIndex, to: position)
            let startDistance = max(0, distance - maxLength / 2)
            let start = text.index(text.startIndex, offsetBy: startDistance)
            let end = text.index(start, offsetBy: min(maxLength, text.distance(from: start, to: text.endIndex)))
            let prefix = start == text.startIndex ? "" : "..."
            let suffix = end == text.endIndex ? "" : "..."
            excerpts.append(prefix + String(text[start..<end]).pocketTrimmed + suffix)
        }
        return excerpts
    }

    private static func compactText(_ content: String) -> String {
        WikiTextParser.stripFrontmatter(content)
            .pocketReplacingMatches(pattern: "```[\\s\\S]*?```", with: " ")
            .pocketReplacingMatches(pattern: "!\\[[^\\]]*\\]\\([^)]+\\)", with: " ")
            .pocketReplacingMatches(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]", with: "$2$1")
            .pocketReplacingMatches(pattern: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1")
            .pocketReplacingMatches(pattern: "[#*_`>|]", with: " ")
            .pocketReplacingMatches(pattern: "\\s+", with: " ")
            .pocketTrimmed
    }

    private static func fold(_ value: String) -> String {
        value
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static func singleLine(_ value: String) -> String {
        value.pocketReplacingMatches(pattern: "\\s+", with: " ").pocketTrimmed
    }

    private static func fit(_ text: String, maxCharacters: Int) -> String {
        let limit = max(1_500, maxCharacters)
        guard text.count > limit else { return text }
        let marker = "\n\n[contexto truncado pelo limite configurado]"
        let available = max(0, limit - marker.count)
        return String(text.prefix(available)) + marker
    }
}
