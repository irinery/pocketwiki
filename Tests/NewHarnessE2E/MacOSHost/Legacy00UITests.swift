import XCTest

final class Legacy00UITests: XCTestCase {
    private var temporaryRoot: URL!
    private var wikiRoot: URL!
    private var memoryStoreRoot: URL!
    private var envFile: URL!
    private var fixtureProviderURL: String!
    private var middlewareURL: String!
    private var kernelURL: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketwiki-legacy00-\(UUID().uuidString)", isDirectory: true)
        wikiRoot = temporaryRoot.appendingPathComponent("wiki", isDirectory: true)
        memoryStoreRoot = temporaryRoot.appendingPathComponent("memory-store", isDirectory: true)
        fixtureProviderURL = try XCTUnwrap(ProcessInfo.processInfo.environment["NH_TEST_FIXTURE_PROVIDER_URL"])
        middlewareURL = try XCTUnwrap(ProcessInfo.processInfo.environment["NH_TEST_MIDDLEWARE_URL"])
        kernelURL = try XCTUnwrap(ProcessInfo.processInfo.environment["NH_TEST_KERNEL_URL"])
        try FileManager.default.createDirectory(at: wikiRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memoryStoreRoot, withIntermediateDirectories: true)
        try Data("---\ntitle: NH-TEST fixture page\nstatus: validated\ntrust: high\n---\n\n# NH-TEST fixture page\n\nfixture evidence: nh-test-marker-2026\n".utf8)
            .write(to: wikiRoot.appendingPathComponent("index.md"))

        envFile = temporaryRoot.appendingPathComponent("pocketwiki.env")
        let env = [
            "POCKETWIKI_REFERENCE_PATH=\(wikiRoot.path)",
            "POCKETWIKI_REFERENCE_READONLY=true",
            "POCKETWIKI_MEMORY_PATH=\(memoryStoreRoot.path)",
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
            "NH_TEST_FIXTURE_PROVIDER_URL": fixtureProviderURL,
            "POCKETWIKI_CONVERSATION_STORE_PATH": memoryStoreRoot.path
        ]

        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "O app legado macOS real não iniciou")
        selectFixtureWiki(in: app)
        openFixturePage(in: app)
        assertReaderShowsFixtureTitle(in: app)

        sendFixturePrompt(in: app)
        let answer = app.descendants(matching: .any).matching(identifier: "legacy.ai.message.assistant").firstMatch
        let gotAnswer = answer.waitForExistence(timeout: 60)
        let visibleStatus = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        let sendButton = app.buttons["legacy.ai.send"]
        XCTAssertTrue(
            gotAnswer,
            "A resposta não chegou pela bridge real Kernel/MiddlewareAuth. status=\(visibleStatus); enviarHabilitado=\(sendButton.isEnabled); prompt=\(String(describing: app.textViews["legacy.ai.prompt"].value))"
        )
        assertFixtureMarkerVisible(in: app, message: "A resposta fixture não trouxe a evidência local esperada")
        waitForPortableConversationArchive()

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "O app legado não encerrou para o teste de restart")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "O app legado não reiniciou")

        let fixtureRow = fixturePageButton(in: app)
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 20), "A wiki temporária não foi restaurada após restart")
        app.buttons["legacy.tab.localAI"].click()
        let restoredAnswer = app.descendants(matching: .any).matching(identifier: "legacy.ai.message.assistant").firstMatch
        XCTAssertTrue(restoredAnswer.waitForExistence(timeout: 20), "A sessão da conversa não foi restaurada depois do restart")
        assertFixtureMarkerVisible(in: app, message: "A resposta restaurada perdeu o conteúdo fixture")
    }

    private func waitForPortableConversationArchive() {
        let archivePredicate = NSPredicate { _, _ in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: self.memoryStoreRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return false }

            return files
                .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }
                .contains { file in
                    guard let data = try? Data(contentsOf: file),
                          let contents = String(data: data, encoding: .utf8) else { return false }
                    return contents.contains("nh-test-marker-2026")
                }
        }
        let expectation = XCTNSPredicateExpectation(predicate: archivePredicate, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10),
            .completed,
            "A resposta fixture não foi gravada no store portátil antes do restart"
        )
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
        let fixtureRow = fixturePageButton(in: app)
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 20), "A fixture não apareceu na sidebar")
        fixtureRow.click()
        XCTAssertTrue(app.staticTexts["legacy.reader.title"].waitForExistence(timeout: 10), "O reader não abriu a fixture")
    }

    private func fixturePageButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(identifier: "legacy.sidebar.item.NH-TEST fixture page")
            .matching(NSPredicate(format: "label CONTAINS %@", "index.md"))
            .firstMatch
    }

    private func assertReaderShowsFixtureTitle(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["legacy.reader.title"]
        let actual = (title.value as? String)?.isEmpty == false ? title.value as? String : title.label
        XCTAssertEqual(
            actual,
            "NH-TEST fixture page",
            "Leitor expôs label=\(title.label.debugDescription), value=\(String(describing: title.value)), element=\(title.debugDescription)",
            file: file,
            line: line
        )
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
        baseURL.typeKey("a", modifierFlags: [.command])
        baseURL.typeText(fixtureProviderURL)
        apiKey.click()
        apiKey.typeKey("a", modifierFlags: [.command])
        apiKey.typeText("nh-test-provider-key")
        settings.buttons["Fechar"].click()
        let providerStatus = app.descendants(matching: .any).matching(identifier: "legacy.ai.provider.status").firstMatch
        XCTAssertTrue(providerStatus.waitForExistence(timeout: 10), "O status do provider não apareceu depois de fechar as configurações")
        let previousStatus = (providerStatus.value as? String) ?? providerStatus.label
        app.buttons["legacy.ai.provider.configure"].click()
        waitForProviderSetup(in: app, previousStatus: previousStatus)

        let prompt = app.textViews["legacy.ai.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "O editor da conversa não expôs accessibility ID")
        prompt.click()
        prompt.typeText("Qual é o status do marcador fixture evidence registrado na wiki?")
        app.buttons["legacy.ai.send"].click()
    }

    private func waitForProviderSetup(in app: XCUIApplication, previousStatus: String) {
        let status = app.descendants(matching: .any).matching(identifier: "legacy.ai.provider.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "O status do provider não expôs accessibility ID")
        let initialStatus = previousStatus.lowercased()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let text = ((status.value as? String) ?? status.label).lowercased()
            if !text.isEmpty && text != initialStatus && !text.contains("configurando") && !text.contains("carregando") {
                let error = app.descendants(matching: .any).matching(identifier: "legacy.ai.error").firstMatch
                XCTAssertFalse(error.exists, "MiddlewareAuth não configurou o provider: \((error.value as? String) ?? error.label)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let error = app.descendants(matching: .any).matching(identifier: "legacy.ai.error").firstMatch
        XCTFail("O provider não terminou de configurar. status=\((status.value as? String) ?? status.label); erro=\((error.value as? String) ?? error.label)")
    }

    private func assertFixtureMarkerVisible(in app: XCUIApplication, message: String) {
        let assistant = app.descendants(matching: .any).matching(identifier: "legacy.ai.message.assistant").firstMatch
        let gotMarker = assistant.waitForExistence(timeout: 10) && assistant.label.contains("nh-test-marker-2026")
        XCTAssertTrue(
            gotMarker,
            "\(message). Rótulo do balão: \(assistant.label.debugDescription); textos visíveis: \(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })"
        )
    }
}
