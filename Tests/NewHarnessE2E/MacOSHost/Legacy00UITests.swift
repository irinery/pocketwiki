import XCTest

final class Legacy00UITests: XCTestCase {
    private var temporaryRoot: URL!
    private var wikiRoot: URL!
    private var envFile: URL!
    private var fixtureProviderURL: String!
    private var middlewareURL: String!
    private var kernelURL: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketwiki-legacy00-\(UUID().uuidString)", isDirectory: true)
        wikiRoot = temporaryRoot.appendingPathComponent("wiki", isDirectory: true)
        let memoryStore = temporaryRoot.appendingPathComponent("memory-store", isDirectory: true)
        fixtureProviderURL = try XCTUnwrap(ProcessInfo.processInfo.environment["NH_TEST_FIXTURE_PROVIDER_URL"])
        middlewareURL = try XCTUnwrap(ProcessInfo.processInfo.environment["NH_TEST_MIDDLEWARE_URL"])
        kernelURL = try XCTUnwrap(ProcessInfo.processInfo.environment["NH_TEST_KERNEL_URL"])
        try FileManager.default.createDirectory(at: wikiRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memoryStore, withIntermediateDirectories: true)
        try Data("---\ntitle: NH-TEST fixture page\nstatus: validated\ntrust: high\n---\n\n# NH-TEST fixture page\n\nfixture evidence: nh-test-marker-2026\n".utf8)
            .write(to: wikiRoot.appendingPathComponent("index.md"))

        envFile = temporaryRoot.appendingPathComponent("pocketwiki.env")
        let env = [
            "POCKETWIKI_REFERENCE_PATH=\(wikiRoot.path)",
            "POCKETWIKI_REFERENCE_READONLY=true",
            "POCKETWIKI_MEMORY_PATH=\(memoryStore.path)",
            "POCKETWIKI_MEMORY_TOKEN=nh-test-memory-token-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            "POCKETWIKI_PORT=\(try XCTUnwrap(ProcessInfo.processInfo.environment["NH_TEST_POCKETWIKI_PORT"]))",
            "POCKETWIKI_MDNS=false",
            "POCKETWIKI_POCKETKERNEL_MODE=managed",
            "POCKETWIKI_MIDDLEWARE_AUTH_MODE=managed",
            "LM_STUDIO_BASE_URL=\(fixtureProviderURL)",
            "LM_STUDIO_MODEL=nh-test-model",
            "POCKETKERNEL_BASE_URL=\(kernelURL)",
            "MIDDLEWARE_BASE_URL=\(middlewareURL)",
            "MIDDLEWAREAUTH_BASE_URL=\(middlewareURL)",
            ""
        ].joined(separator: "\n")
        try Data(env.utf8).write(to: envFile)

        let appDefaults = try XCTUnwrap(UserDefaults(suiteName: "com.pocketwiki.NHTestHost"))
        appDefaults.removePersistentDomain(forName: "com.pocketwiki.NHTestHost")
        appDefaults.set("lmstudio", forKey: "PocketWikiMac.localAI.providerMethod")
        appDefaults.set("nh-test-model", forKey: "PocketWikiMac.localAI.lmStudioModelID")
        appDefaults.set(fixtureProviderURL, forKey: "PocketWikiMac.localAI.baseURL")
        appDefaults.set(middlewareURL, forKey: "PocketWikiMac.localAI.middlewareBaseURL")
        appDefaults.set(kernelURL, forKey: "PocketWikiMac.localAI.kernelBaseURL")
        appDefaults.set("acme", forKey: "PocketWikiMac.localAI.middlewareProjectID")
        appDefaults.set("default", forKey: "PocketWikiMac.localAI.middlewareProfileID")
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testLegacy00UsesRealAppBridgeAndRestoresAfterRestart() throws {
        let app = XCUIApplication(bundleIdentifier: "com.pocketwiki.NHTestHost")
        app.launchEnvironment = [
            "HOME": ProcessInfo.processInfo.environment["HOME"] ?? temporaryRoot.path,
            "CFFIXED_USER_HOME": ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? temporaryRoot.path,
            "TMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? temporaryRoot.path,
            "POCKETWIKI_ENV_PATH": envFile.path,
            "POCKETWIKI_PORT": try XCTUnwrap(ProcessInfo.processInfo.environment["NH_TEST_POCKETWIKI_PORT"]),
            "POCKETWIKI_BIND_HOST": "127.0.0.1",
            "POCKETWIKI_MDNS": "false",
            "LMSTUDIO_BASE_URL": fixtureProviderURL,
            "MIDDLEWAREAUTH_BASE_URL": middlewareURL,
            "POCKETKERNEL_MIDDLEWAREAUTH_BASE_URL": middlewareURL,
            "POCKETKERNEL_MIDDLEWAREAUTH_PROJECT_ID": "acme",
            "MCP_LMSTUDIO_MODEL": "nh-test-model",
            "POCKETWIKI_POCKETKERNEL_BINARY": try XCTUnwrap(ProcessInfo.processInfo.environment["POCKETWIKI_POCKETKERNEL_BINARY"]),
            "POCKETWIKI_MIDDLEWARE_AUTH_BINARY": try XCTUnwrap(ProcessInfo.processInfo.environment["POCKETWIKI_MIDDLEWARE_AUTH_BINARY"]),
            "POCKETWIKI_NODE_BINARY": try XCTUnwrap(ProcessInfo.processInfo.environment["POCKETWIKI_NODE_BINARY"]),
            "NH_TEST_FIXTURE_PROVIDER_URL": fixtureProviderURL
        ]

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "O app legado macOS real não iniciou")
        selectFixtureWiki(in: app)
        openFixturePage(in: app)
        XCTAssertEqual(app.staticTexts["legacy.reader.title"].label, "NH-TEST fixture page")

        sendFixturePrompt(in: app)
        let answer = app.descendants(matching: .any).matching(identifier: "legacy.ai.message.assistant").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 60), "A resposta não chegou pela bridge real Kernel/MiddlewareAuth")
        XCTAssertTrue(answer.label.contains("nh-test-marker-2026"), "A resposta fixture não trouxe a evidência local esperada")

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "O app legado não encerrou para o teste de restart")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "O app legado não reiniciou")

        let fixtureRow = app.buttons["legacy.sidebar.item.NH-TEST fixture page"]
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 20), "A wiki temporária não foi restaurada após restart")
        fixtureRow.click()
        let restoredTitle = app.staticTexts["legacy.reader.title"]
        XCTAssertTrue(restoredTitle.waitForExistence(timeout: 10), "A página fixture não abriu após restore")
        XCTAssertEqual(restoredTitle.label, "NH-TEST fixture page")
        app.buttons["legacy.tab.localAI"].click()
        let restoredAnswer = app.descendants(matching: .any).matching(identifier: "legacy.ai.message.assistant").firstMatch
        XCTAssertTrue(restoredAnswer.waitForExistence(timeout: 20), "A sessão da conversa não foi restaurada depois do restart")
        XCTAssertTrue(restoredAnswer.label.contains("nh-test-marker-2026"), "A resposta restaurada perdeu o conteúdo fixture")
    }

    private func selectFixtureWiki(in app: XCUIApplication) {
        let openWiki = app.buttons["legacy.openWiki"]
        XCTAssertTrue(openWiki.waitForExistence(timeout: 10), "Botão de abrir wiki sem accessibility ID")
        openWiki.click()

        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "O painel real de seleção de pasta não abriu")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let locationSheet = app.sheets.firstMatch
        let pathField = locationSheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5), "O diálogo do Finder para escolher a pasta não abriu")
        pathField.click()
        pathField.typeText(wikiRoot.path)
        app.typeKey(.return, modifierFlags: [])

        let openButton = panel.buttons["OKButton"]
        XCTAssertTrue(
            openButton.waitForExistence(timeout: 5),
            "O painel não expôs o botão de confirmação. Botões: \(panel.buttons.allElementsBoundByIndex.map { "\($0.identifier)=\($0.label)" }); painel: \(panel.debugDescription)"
        )
        openButton.click()
        XCTAssertFalse(panel.waitForExistence(timeout: 3), "O painel permaneceu aberto depois de confirmar a pasta")
    }

    private func openFixturePage(in app: XCUIApplication) {
        let fixtureRow = app.buttons["legacy.sidebar.item.NH-TEST fixture page"]
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 20), "A fixture não apareceu na sidebar")
        fixtureRow.click()
        XCTAssertTrue(app.staticTexts["legacy.reader.title"].waitForExistence(timeout: 10), "O reader não abriu a fixture")
    }

    private func sendFixturePrompt(in app: XCUIApplication) {
        let aiTab = app.buttons["legacy.tab.localAI"]
        XCTAssertTrue(aiTab.waitForExistence(timeout: 10), "A aba IA não expôs accessibility ID")
        aiTab.click()

        app.buttons["legacy.ai.settings.open"].click()
        let settings = app.sheets.firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "As configurações avançadas do provider não abriram")
        let baseURL = settings.textFields["legacy.ai.auth.baseUrl"]
        let apiKey = settings.secureTextFields["legacy.ai.auth.apiKey"]
        XCTAssertTrue(baseURL.waitForExistence(timeout: 20), "O provider fixture não apareceu no formulário do MiddlewareAuth")
        XCTAssertTrue(apiKey.waitForExistence(timeout: 10), "O campo de credencial do provider fixture não apareceu")
        baseURL.click()
        baseURL.typeText(fixtureProviderURL)
        apiKey.click()
        apiKey.typeText("nh-test-provider-key")
        settings.buttons["Fechar"].click()
        app.buttons["legacy.ai.provider.configure"].click()

        let prompt = app.textViews["legacy.ai.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "O editor da conversa não expôs accessibility ID")
        prompt.click()
        prompt.typeText("Qual é o status do marcador fixture evidence registrado na wiki?")
        app.buttons["legacy.ai.send"].click()
    }
}
