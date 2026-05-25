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
            ("excalidraw size limit", testExcalidrawSizeLimit),
            ("oversized excalidraw load issue", testOversizedExcalidrawLoadIssue),
            ("excalidraw editor resource resolver", testExcalidrawEditorResourceResolver),
            ("extension kind", testKindRecognition),
            ("excalidraw json", testExcalidrawJSON),
            ("excalidraw markdown json fence", testExcalidrawMarkdownJSONFence),
            ("excalidraw markdown fallback", testExcalidrawMarkdownFallback),
            ("excalidraw invalid fallback", testInvalidExcalidraw),
            ("excalidraw preview clamp source", testExcalidrawPreviewLimitSource),
            ("safe wiki file path", testSafeWikiFilePath),
            ("analytics", testAnalytics),
            ("timeline", testTimeline),
            ("markdown strips duplicate title", testMarkdownStripsDuplicateTitle),
            ("markdown display links", testMarkdownDisplayLinks),
            ("local ai endpoint policy", testLocalAIEndpointPolicy),
            ("local ai runtime configuration", testLocalAIRuntimeConfiguration),
            ("local ai model parsing", testLocalAIModelParsing),
            ("local ai chat parsing", testLocalAIChatParsing),
            ("local ai remote proxy endpoint", testLocalAIRemoteProxyEndpoint),
            ("local ai context builder", testLocalAIContextBuilder),
            ("local ai automatic context", testLocalAIAutomaticContext),
            ("local ai manual context", testLocalAIManualContext),
            ("local ai response linkifier", testLocalAIResponseLinkifier),
            ("server configuration", testServerConfiguration),
            ("server routes", testServerRoutes),
            ("server files payload", testServerFilesPayload),
            ("remote wiki decode", testRemoteWikiDecode),
            ("sidebar explorer", testSidebarExplorer),
            ("desktop tabs include map and server", testDesktopTabs)
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

    static func testExcalidrawSizeLimit() throws {
        let loader = WikiFolderLoader()
        try expect(loader.isEligible(
            relativePath: "Grande.excalidraw",
            isDirectory: false,
            sizeBytes: WikiFolderLoader.maxFileSizeBytes + 1
        ), "excalidraw above markdown limit rejected")
        try expect(!loader.isEligible(
            relativePath: "Imenso.excalidraw",
            isDirectory: false,
            sizeBytes: WikiFolderLoader.maxExcalidrawFileSizeBytes + 1
        ), "oversized excalidraw accepted")
    }

    static func testOversizedExcalidrawLoadIssue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketWikiCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("Imenso.excalidraw")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(WikiFolderLoader.maxExcalidrawFileSizeBytes + 1))
        try handle.close()

        let loaded = try WikiFolderLoader().loadFiles(from: root)
        try expect(loaded.files.isEmpty, "oversized excalidraw loaded")
        try expect(loaded.issues.contains { $0.contains("excalidraw ignorado por tamanho") && $0.contains("Imenso.excalidraw") }, "oversized issue missing")
    }

    static func testExcalidrawEditorResourceResolver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketWikiExcalidrawResolver-\(UUID().uuidString)", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "<html></html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log('ok')".write(to: assets.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let resolver = ExcalidrawEditorResourceResolver(root: root)

        let indexURL = try require(URL(string: "pocketwiki-excalidraw://bundle/index.html"), "index resource url failed")
        let index = try resolver.resolve(indexURL)
        try expect(index.mimeType == "text/html", "index mime failed")
        try expect(String(data: index.data, encoding: .utf8) == "<html></html>", "index data failed")

        let assetURL = try require(URL(string: "pocketwiki-excalidraw://bundle/assets/index.js"), "asset resource url failed")
        let asset = try resolver.resolve(assetURL)
        try expect(asset.mimeType == "text/javascript", "js mime failed")

        do {
            _ = try resolver.relativePath(for: try require(URL(string: "pocketwiki-excalidraw://bundle/../secret.js"), "escape url failed"))
            throw TestFailure.failed("resource path escape accepted")
        } catch ExcalidrawEditorResourceError.invalidPath {
            // expected
        }
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

    static func testExcalidrawMarkdownJSONFence() throws {
        let file = makeFile(
            path: "Mapa.excalidraw.md",
            content: """
            # Mapa

            ## Drawing

            ```json
            {"type":"excalidraw","elements":[{"id":"1","type":"text","rawText":"Firewall [[Rede]]"}]}
            ```
            """,
            kind: .excalidrawMarkdown
        )

        let summary = ExcalidrawParser.summary(file: file)
        try expect(summary.texts == ["Firewall [[Rede]]"], "json fence text failed")
        try expect(summary.links.first?.target == "Rede", "json fence link failed")
        try expect(summary.fallbackReason == nil, "json fence should not fallback")
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

    static func testSafeWikiFilePath() throws {
        let root = URL(fileURLWithPath: "/tmp/PocketWikiRoot", isDirectory: true)
        let valid = try WikiFilePathResolver.fileURL(root: root, relativePath: "drawings/Mapa.excalidraw")
        try expect(valid.path == "/tmp/PocketWikiRoot/drawings/Mapa.excalidraw", "safe path failed")

        do {
            _ = try WikiFilePathResolver.fileURL(root: root, relativePath: "../escape.excalidraw")
            throw TestFailure.failed("path escape accepted")
        } catch WikiFilePathResolverError.invalidRelativePath {
            // expected
        }

        do {
            _ = try WikiFilePathResolver.fileURL(root: root, relativePath: "/tmp/escape.excalidraw")
            throw TestFailure.failed("absolute path accepted")
        } catch WikiFilePathResolverError.invalidRelativePath {
            // expected
        }
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

    static func testLocalAIEndpointPolicy() throws {
        let chatURL = try LocalAIEndpointPolicy.endpointURL(
            baseURL: "http://127.0.0.1:1234/v1",
            path: "chat/completions"
        )
        try expect(chatURL.absoluteString == "http://127.0.0.1:1234/v1/chat/completions", "chat endpoint url failed")

        let rootModelsURL = try LocalAIEndpointPolicy.endpointURL(
            baseURL: "http://127.0.0.1:1234",
            path: "models"
        )
        try expect(rootModelsURL.absoluteString == "http://127.0.0.1:1234/v1/models", "lm studio root endpoint was not normalized to /v1")

        try expect(LocalAIEndpointPolicy.isAllowedLocalBaseURL(URL(string: "http://localhost:1234/v1")!), "localhost blocked")
        try expect(LocalAIEndpointPolicy.isAllowedLocalBaseURL(URL(string: "http://[::1]:1234/v1")!), "ipv6 loopback blocked")
        try expect(LocalAIEndpointPolicy.isAllowedLocalBaseURL(URL(string: "http://192.168.2.20:1234/v1")!), "private lan endpoint blocked")
        try expect(LocalAIEndpointPolicy.isAllowedLocalBaseURL(URL(string: "http://10.0.0.10:1234/v1")!), "private 10 endpoint blocked")
        try expect(LocalAIEndpointPolicy.isAllowedLocalBaseURL(URL(string: "http://172.20.1.2:1234/v1")!), "private 172 endpoint blocked")
        try expect(LocalAIEndpointPolicy.isAllowedLocalBaseURL(URL(string: "http://pocketwiki.local:1234/v1")!), "mdns endpoint blocked")
        try expect(!LocalAIEndpointPolicy.isAllowedLocalBaseURL(URL(string: "https://example.com/v1")!), "remote endpoint accepted")
        try expect(!LocalAIEndpointPolicy.isAllowedLocalBaseURL(URL(string: "http://8.8.8.8:1234/v1")!), "public ipv4 endpoint accepted")

        do {
            _ = try LocalAIEndpointPolicy.normalizedBaseURL("https://example.com/v1")
            throw TestFailure.failed("remote endpoint did not throw")
        } catch LocalAIEndpointPolicyError.nonLocalEndpoint {
            // expected
        }
    }

    static func testLocalAIRuntimeConfiguration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let envURL = tempDir.appendingPathComponent(".env")
        try """
        LM_STUDIO_BASE_URL="http://localhost:1234/v1"
        LM_STUDIO_API_KEY='secret-token'
        LM_STUDIO_MODEL=qwen-chat
        """.write(to: envURL, atomically: true, encoding: .utf8)

        let config = LocalAIRuntimeConfigurationLoader.load(environment: [
            "POCKETWIKI_ENV_PATH": envURL.path
        ])

        try expect(config.baseURL == "http://localhost:1234/v1", "runtime base url failed")
        try expect(config.apiKey == "secret-token", "runtime token failed")
        try expect(config.modelID == "qwen-chat", "runtime model failed")
        try expect(config.hasToken, "runtime token flag failed")
    }

    static func testLocalAIModelParsing() throws {
        let models = try LMStudioClient.parseModelsResponse(Data("""
        {
          "models": [
            {"name":"qwen-chat","type":"llm"},
            {"id":"nomic-embed-text","type":"embedding"},
            "plain-chat"
          ]
        }
        """.utf8))

        try expect(models.map(\.id) == ["qwen-chat", "plain-chat"], "flexible model parser failed")

        let openAIModels = try LMStudioClient.parseModelsResponse(Data("""
        {"data":[{"id":"openai/gpt-oss-20b","owned_by":"lmstudio"}]}
        """.utf8))
        try expect(openAIModels.map(\.id) == ["openai/gpt-oss-20b"], "openai model parser failed")
    }

    static func testLocalAIChatParsing() throws {
        let streamed = try LMStudioClient.parseChatCompletionResponse(Data("""
        {"model":"qwen","choices":[{"delta":{"content":"oi"},"finish_reason":null}]}
        """.utf8))
        try expect(streamed.content == "oi", "streaming chat content failed")
        try expect(streamed.modelID == "qwen", "streaming chat model failed")

        let plain = try LMStudioClient.parseChatCompletionResponse(Data("""
        {"model":"qwen","choices":[{"message":{"content":"resposta final"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}
        """.utf8))
        try expect(plain.content == "resposta final", "non-stream chat content failed")
        try expect(plain.finishReason == "stop", "non-stream finish reason failed")
        try expect(plain.usageSummary == "prompt 2 · resposta 3 · total 5", "non-stream usage failed")
    }

    static func testLocalAIRemoteProxyEndpoint() throws {
        let modelsURL = try LocalAIEndpointPolicy.endpointURL(baseURL: "http://100.80.1.2/api/ai", path: "models")
        try expect(modelsURL.absoluteString == "http://100.80.1.2/api/ai/models", "remote proxy models url failed")

        let chatURL = try LocalAIEndpointPolicy.endpointURL(baseURL: "http://pocketwiki.local/api/ai", path: "chat/completions")
        try expect(chatURL.absoluteString == "http://pocketwiki.local/api/ai/chat", "remote proxy chat url failed")
    }

    static func testLocalAIContextBuilder() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "A.md", content: "# A\nConteudo A\n[[B]]"),
            makeFile(path: "B.md", content: "# B\nConteudo B"),
            makeFile(path: "C.md", content: "# C\nConteudo C")
        ], sourceName: "Test")

        let linked = LocalAIContextBuilder.build(
            index: index,
            selectedPageID: "a",
            scope: .linkedPages,
            maxCharacters: 3_000
        )
        try expect(linked.includedPaths == ["A.md", "B.md"], "linked context selected wrong pages")
        try expect(linked.body.contains("Conteudo A") && linked.body.contains("Conteudo B"), "linked context missing page body")
        try expect(!linked.body.contains("Conteudo C"), "linked context leaked unrelated page")

        let longIndex = WikiIndexer().buildIndex(files: [
            makeFile(path: "Long.md", content: "# Long\n" + String(repeating: "texto ", count: 1_000))
        ], sourceName: "Test")
        let fitted = LocalAIContextBuilder.build(
            index: longIndex,
            selectedPageID: "long",
            scope: .currentPage,
            maxCharacters: 1_500
        )
        try expect(fitted.characters <= 1_500, "context was not truncated")
        try expect(fitted.body.contains("contexto truncado"), "truncation marker missing")
    }

    static func testLocalAIAutomaticContext() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "Rede.md", content: "# Rede\nVLAN IoT no MikroTik com DNS e DHCP."),
            makeFile(path: "Receitas.md", content: "# Receitas\nBolo de cenoura.")
        ], sourceName: "Test")

        let context = LocalAIContextBuilder.build(
            index: index,
            selectedPageID: nil,
            scope: .automatic,
            maxCharacters: 4_000,
            question: "Como esta a VLAN IoT no roteador?"
        )
        try expect(context.mode == .wiki, "automatic context should use wiki mode")
        try expect(context.includedPaths == ["Rede.md"], "automatic context selected wrong page")
        try expect(context.body.contains("VLAN IoT"), "automatic context missing relevant excerpt")

        let general = LocalAIContextBuilder.build(
            index: index,
            selectedPageID: nil,
            scope: .automatic,
            maxCharacters: 4_000,
            question: "oi"
        )
        try expect(general.mode == .general, "simple greeting should not load wiki context")
        try expect(general.includedPaths.isEmpty, "general context should not include pages")

        let noMatch = LocalAIContextBuilder.build(
            index: index,
            selectedPageID: nil,
            scope: .automatic,
            maxCharacters: 4_000,
            question: "Como configuro proxmox com ceph?"
        )
        try expect(noMatch.mode == .wiki, "no-match wiki question should stay grounded to index")
        try expect(noMatch.includedPaths.isEmpty, "no-match context should not invent included pages")
        try expect(noMatch.body.contains("Indice base da wiki"), "no-match context should include index snapshot")
        try expect(noMatch.body.contains("Nenhuma pagina passou"), "no-match context should state no page passed relevance")
    }

    static func testLocalAIManualContext() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "Rede.md", content: "# Rede\nVLAN IoT no MikroTik."),
            makeFile(path: "Camera.md", content: "# Camera\nScrypted e HomeKit.")
        ], sourceName: "Test")
        let manual = LocalAIManualContextSource(
            title: "extra.txt",
            path: "/tmp/extra.txt",
            content: "Contexto extra escolhido manualmente."
        )

        let context = LocalAIContextBuilder.build(
            index: index,
            selectedPageID: nil,
            scope: .automatic,
            maxCharacters: 4_000,
            question: "Como esta a VLAN IoT?",
            manualSources: [manual],
            excludedPaths: ["Rede.md"]
        )

        try expect(!context.includedPaths.contains("Rede.md"), "excluded wiki path leaked into context")
        try expect(context.manualPaths == ["/tmp/extra.txt"], "manual path missing")
        try expect(context.includedPaths.contains("/tmp/extra.txt"), "manual included path missing")
        try expect(context.body.contains("Contexto extra escolhido manualmente."), "manual body missing")
    }

    static func testLocalAIResponseLinkifier() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "wiki/index.md", content: "# Index"),
            makeFile(path: "raw/skill_chatgpt_markdown.md", content: "# Skill")
        ], sourceName: "Test")
        let linked = LocalAIResponseLinkifier.linkify("""
        - **Path:** wiki/index.md
        - Path: raw/skill_chatgpt_markdown.md
        - Path: missing.md
        """, index: index)

        try expect(linked.contains("**Path:** [wiki/index.md](pocketwiki://page/index)"), "bold path link failed")
        try expect(linked.contains("Path: [raw/skill_chatgpt_markdown.md](pocketwiki://page/raw/skill_chatgpt_markdown)"), "plain path link failed")
        try expect(linked.contains("Path: missing.md"), "missing path should stay plain")
    }

    static func testServerConfiguration() throws {
        let config = PocketWikiServerConfiguration.load(environment: [
            "POCKETWIKI_PORT": "9090",
            "POCKETWIKI_BIND_HOST": "127.0.0.1",
            "POCKETWIKI_PUBLIC_HOSTS": "pocketwiki.local,desk",
            "POCKETWIKI_MDNS": "false",
            "POCKETWIKI_REFERENCE_READONLY": "false",
            "LM_STUDIO_BASE_URL": "http://localhost:1234/v1/",
            "LM_STUDIO_MODEL": "qwen"
        ])

        try expect(config.port == 9090, "server port parse failed")
        try expect(config.bindHost == "127.0.0.1", "bind host parse failed")
        try expect(config.publicHosts == ["pocketwiki.local", "desk.local"], "public host normalization failed")
        try expect(!config.mdnsEnabled, "mdns bool parse failed")
        try expect(!config.referenceReadonly, "readonly bool parse failed")
        try expect(config.lmStudioBaseURL == "http://localhost:1234/v1", "lm studio slash trim failed")
        try expect(config.lmStudioModel == "qwen", "lm studio model parse failed")
    }

    static func testServerRoutes() throws {
        let routes = PocketWikiRouteBuilder.build(
            port: 80,
            bindHost: "0.0.0.0",
            publicHosts: ["pocketwiki.local"],
            addresses: ["192.168.1.20", "100.80.1.2", "8.8.8.8"]
        )

        try expect(routes.portless, "portless route failed")
        try expect(routes.local == ["http://localhost", "http://127.0.0.1"], "local route failed")
        try expect(routes.mdns == ["http://pocketwiki.local"], "mdns route failed")
        try expect(routes.lan.contains("http://192.168.1.20"), "lan route failed")
        try expect(routes.tailscale == ["http://100.80.1.2"], "tailscale route failed")
    }

    static func testServerFilesPayload() throws {
        let source = PocketWikiServedSource(
            rootName: "Wiki",
            source: "desktop",
            configured: true,
            readonly: true,
            available: true,
            status: "ready",
            files: [makeFile(path: "A.md", content: "# A")]
        )
        let payload = PocketWikiFilesPayload(source: source)
        let data = try JSONEncoder().encode(payload)
        let json = try require(String(data: data, encoding: .utf8), "files payload json missing")

        try expect(json.contains(#""rootName":"Wiki""#), "files payload root missing")
        try expect(json.contains(#""path":"A.md""#), "files payload path missing")
        try expect(json.contains(##""content":"# A""##), "files payload content missing")
    }

    static func testRemoteWikiDecode() throws {
        let source = try RemoteWikiClient.decodeWikiFilesResponse(Data("""
        {
          "rootName":"Remote",
          "readonly":true,
          "source":"env",
          "configured":true,
          "available":true,
          "status":"ready",
          "files":[
            {"path":"A.md","name":"A.md","size":5,"type":"text/markdown","updated":1000,"content":"# A"},
            {"path":"asset.png","name":"asset.png","size":2,"type":"image/png","updated":1000,"content":null}
          ]
        }
        """.utf8))

        try expect(source.rootName == "Remote", "remote root failed")
        try expect(source.files.count == 1, "remote non-indexable file was not filtered")
        try expect(source.files[0].relativePath == "A.md", "remote file path failed")
        try expect(source.files[0].modifiedAt == Date(timeIntervalSince1970: 1), "remote timestamp failed")
    }

    static func testSidebarExplorer() throws {
        let index = WikiIndexer().buildIndex(files: [
            makeFile(path: "A.md", content: "# A\n[[B]] #infra"),
            makeFile(path: "B.md", content: "# B\n[[Missing]]")
        ], sourceName: "Test")

        let sections = WikiSidebarExplorer.sections(index: index, selectedPageID: "a", query: "")
        try expect(sections.map(\.title).contains("Atual"), "sidebar current section missing")
        try expect(sections.map(\.title).contains("Relacionadas"), "sidebar related section missing")
        try expect(sections.flatMap(\.items).contains { $0.title == "#infra" }, "sidebar tags missing")

        let search = WikiSidebarExplorer.sections(index: index, selectedPageID: nil, query: "missing")
        try expect(search.count == 1 && search[0].title == "Busca", "sidebar search mode failed")
    }

    static func testDesktopTabs() throws {
        let tabs = WikiTab.allCases
        try expect(tabs.contains(.map), "map tab missing")
        try expect(tabs.contains(.server), "server tab missing")
        try expect(WikiTab.map.iconKind == .map, "map icon kind failed")
        try expect(WikiTab.server.iconKind == .server, "server icon kind failed")
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
