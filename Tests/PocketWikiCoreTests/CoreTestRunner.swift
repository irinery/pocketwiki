import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw TestFailure.failed(message)
    }
    return value
}

@main
struct CoreTestRunner {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("slug path", testPathToSlug),
            ("frontmatter", testFrontmatter),
            ("tags ignore code", testTagsIgnoreCodeBlocks),
            ("wiki links", testWikiLinks),
            ("summary fallback", testSummaryFallback),
            ("resolved links", testResolvedLinks),
            ("missing links", testMissingLinks),
            ("folder eligibility", testFolderEligibility),
            ("file size limit", testFileSizeLimit),
            ("extension kind", testKindRecognition),
            ("excalidraw json", testExcalidrawJSON),
            ("excalidraw markdown fallback", testExcalidrawMarkdownFallback),
            ("excalidraw invalid fallback", testInvalidExcalidraw),
            ("excalidraw preview clamp source", testExcalidrawPreviewLimitSource),
            ("analytics", testAnalytics),
            ("timeline", testTimeline),
            ("markdown strips duplicate title", testMarkdownStripsDuplicateTitle),
            ("markdown display links", testMarkdownDisplayLinks)
        ]

        for (name, test) in tests {
            try test()
            print("ok - \(name)")
        }

        print("\(tests.count) core tests passing")
    }

    static func testPathToSlug() throws {
        try expect(WikiTextParser.pathToSlug("Wiki/Minha Página.md") == "minha-pagina", "slug mismatch")
    }

    static func testFrontmatter() throws {
        let markdown = """
        ---
        title: "Servidor Principal"
        summary: "Resumo curto"
        updated: 2026-05-20
        ---
        # Outro titulo
        Corpo.
        """

        try expect(WikiTextParser.title(from: markdown, fallback: "fallback") == "Servidor Principal", "frontmatter title failed")
        try expect(WikiTextParser.extractSummary(markdown) == "Resumo curto", "frontmatter summary failed")

        let date = try require(WikiTextParser.extractUpdated(markdown, lastModified: nil), "frontmatter date missing")
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        try expect(components.year == 2026 && components.month == 5 && components.day == 20, "frontmatter date failed")
    }

    static func testTagsIgnoreCodeBlocks() throws {
        let markdown = """
        # Rede #infra

        ```sh
        echo #nao
        ```

        Texto #zabbix/iot
        """

        try expect(WikiTextParser.extractTags(markdown) == ["infra", "zabbix/iot"], "tags failed")
    }

    static func testWikiLinks() throws {
        let links = WikiTextParser.extractWikiLinks("[[Rede|minha rede]] [[Rede]] [[Servidor#DNS]]")
        try expect(links.count == 2, "unique links failed")
        try expect(links[0].target == "Rede" && links[0].label == "minha rede", "alias link failed")
        try expect(links[1].target == "Servidor" && links[1].heading == "DNS", "heading link failed")
    }

    static func testSummaryFallback() throws {
        let markdown = """
        # Titulo

        Primeiro paragrafo com [[Rede|alias]] e **marcacao**.
        """
        try expect(WikiTextParser.extractSummary(markdown) == "Primeiro paragrafo com aliasRede e marcacao.", "summary fallback failed")
    }

    static func testResolvedLinks() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "A.md", content: "# A\n[[B|label]]"),
            makeFile(path: "B.md", content: "# B\nConteudo")
        ], sourceName: "Test")

        let pageA = try require(index.page(id: "a"), "page a missing")
        let pageB = try require(index.page(id: "b"), "page b missing")
        try expect(pageA.outlinks.map(\.resolvedPageID) == ["b"], "outlink resolution failed")
        try expect(pageB.backlinks == ["a"], "backlink resolution failed")
        try expect(pageA.missingLinks.isEmpty, "unexpected missing link")
    }

    static func testMissingLinks() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "A.md", content: "# A\n[[Nao Existe]]")
        ], sourceName: "Test")

        let pageA = try require(index.page(id: "a"), "page a missing")
        try expect(pageA.missingLinks.first?.target == "Nao Existe", "missing target failed")
        try expect(index.missingLinks["nao-existe"] == ["a"], "missing index failed")
    }

    static func testFolderEligibility() throws {
        let loader = WikiFolderLoader()
        try expect(!loader.isEligible(relativePath: ".git/config", isDirectory: false, sizeBytes: 10), ".git not ignored")
        try expect(!loader.isEligible(relativePath: "node_modules/pkg/readme.md", isDirectory: false, sizeBytes: 10), "node_modules not ignored")
        try expect(!loader.isEligible(relativePath: ".pocketwiki-cache/a.md", isDirectory: false, sizeBytes: 10), "cache not ignored")
        try expect(!loader.isEligible(relativePath: "build/a.md", isDirectory: false, sizeBytes: 10), "build not ignored")
        try expect(loader.isEligible(relativePath: "Notas/a.md", isDirectory: false, sizeBytes: 10), "valid md ignored")
    }

    static func testFileSizeLimit() throws {
        let loader = WikiFolderLoader()
        try expect(!loader.isEligible(relativePath: "Grande.md", isDirectory: false, sizeBytes: WikiFolderLoader.maxFileSizeBytes + 1), "large file accepted")
    }

    static func testKindRecognition() throws {
        let loader = WikiFolderLoader()
        try expect(loader.kind(for: "a.md") == .markdown, "md kind failed")
        try expect(loader.kind(for: "a.excalidraw") == .excalidraw, "excalidraw kind failed")
        try expect(loader.kind(for: "a.excalidraw.md") == .excalidrawMarkdown, "excalidraw md kind failed")
        try expect(loader.kind(for: "a.txt") == nil, "txt accepted")
    }

    static func testExcalidrawJSON() throws {
        let file = makeFile(
            path: "Mapa.excalidraw",
            content: #"{"type":"excalidraw","elements":[{"id":"1","type":"text","rawText":"Servidor [[Rede]]"}]}"#,
            kind: .excalidraw
        )

        let summary = ExcalidrawParser.summary(file: file)
        try expect(summary.texts == ["Servidor [[Rede]]"], "excalidraw text failed")
        try expect(summary.links.first?.target == "Rede", "excalidraw link failed")
        try expect(summary.fallbackReason == nil, "unexpected excalidraw fallback")
    }

    static func testExcalidrawMarkdownFallback() throws {
        let file = makeFile(
            path: "Mapa.excalidraw.md",
            content: """
            # Mapa

            Servidor -> Switch
            Camera [[IoT]]
            """,
            kind: .excalidrawMarkdown
        )

        let summary = ExcalidrawParser.summary(file: file)
        try expect(summary.texts.contains("Servidor -> Switch"), "fallback relation line missing")
        try expect(summary.texts.contains("Camera [[IoT]]"), "fallback wiki line missing")
        try expect(summary.links.first?.target == "IoT", "fallback link failed")
        try expect(summary.fallbackReason == "fallback textual", "fallback reason failed")
    }

    static func testInvalidExcalidraw() throws {
        let summary = ExcalidrawParser.summary(file: makeFile(path: "Quebrado.excalidraw", content: "{", kind: .excalidraw))
        try expect(summary.texts.isEmpty, "invalid excalidraw should be empty")
        try expect(summary.fallbackReason == "sem texto extraivel", "invalid fallback reason failed")
    }

    static func testExcalidrawPreviewLimitSource() throws {
        let lines = (0..<100).map { "Texto \($0)" }.joined(separator: "\n")
        let summary = ExcalidrawParser.summary(file: makeFile(path: "Grande.excalidraw.md", content: lines, kind: .excalidrawMarkdown))
        try expect(summary.texts.count == 100, "source text count failed")
        try expect(Array(summary.texts.prefix(80)).count == 80, "preview clamp source failed")
    }

    static func testAnalytics() throws {
        let now = try require(PocketWikiDateParser.parse("2026-05-20"), "now parse failed")
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "A.md", content: "# A\n[[B]] [[Missing]]"),
            makeFile(path: "B.md", content: "---\nsummary: ok\nupdated: 2025-01-01\n---\n# B"),
            makeFile(path: "C.md", content: "# C\nSem links")
        ], sourceName: "Test")

        let metrics = WikiAnalytics.metrics(for: index)
        try expect(metrics.pages == 3, "metrics pages failed")
        try expect(metrics.links == 2, "metrics links failed")
        try expect(metrics.missingDestinations == 1, "metrics missing failed")

        let issues = WikiAnalytics.healthIssues(for: index, now: now)
        try expect(issues.contains { $0.id == "missing-links" && $0.priority == .high }, "missing issue failed")
        try expect(issues.contains { $0.id == "stale" && $0.priority == .low }, "stale issue failed")
    }

    static func testTimeline() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "Old.md", content: "---\nupdated: 2025-01-01\n---\n# Old"),
            makeFile(path: "New.md", content: "---\nupdated: 2026-01-01\n---\n# New")
        ], sourceName: "Test")

        try expect(WikiAnalytics.timelinePages(in: index).map(\.slug) == ["new", "old"], "timeline order failed")
    }

    static func testMarkdownStripsDuplicateTitle() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "A.md", content: "# Titulo\n\nTexto comum\n\n- item\n\n```sh\necho ok\n```")
        ], sourceName: "Test")
        let page = try require(index.page(id: "a"), "page a missing")
        let display = WikiMarkdownFormatter.markdownForDisplay(page: page, index: index)

        try expect(!display.hasPrefix("# Titulo"), "duplicate title heading was not stripped")
        try expect(display.contains("Texto comum"), "markdown body was stripped unexpectedly")
        try expect(display.contains("```sh\necho ok\n```"), "code block was stripped unexpectedly")
    }

    static func testMarkdownDisplayLinks() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "A.md", content: "# A\nIr para [[B|pagina B]] e [[C]]"),
            makeFile(path: "B.md", content: "# B")
        ], sourceName: "Test")
        let page = try require(index.page(id: "a"), "page a missing")
        let display = WikiMarkdownFormatter.markdownForDisplay(page: page, index: index)

        try expect(display.contains("[pagina B](pocketwiki://page/b)"), "resolved wiki link was not converted")
        try expect(display.contains("**C**"), "missing wiki link was not highlighted")
    }

    private static func makeFile(path: String, content: String, kind: WikiFile.Kind = .markdown) -> WikiFile {
        WikiFile(
            relativePath: path,
            sizeBytes: content.utf8.count,
            modifiedAt: Date(timeIntervalSince1970: 0),
            content: content,
            kind: kind
        )
    }
}
