import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum ExcalidrawDocumentPersistenceError: Error, LocalizedError {
    case noLocalSource
    case readonlySource
    case invalidExtension
    case fileExists

    var errorDescription: String? {
        switch self {
        case .noLocalSource:
            "Nenhuma pasta local aberta."
        case .readonlySource:
            "Fonte atual esta em modo somente leitura."
        case .invalidExtension:
            "Arquivo precisa ser .excalidraw ou .excalidraw.md."
        case .fileExists:
            "Arquivo ja existe."
        }
    }
}

@MainActor
@Observable
final class WikiAppStore {
    var index: WikiIndex = .empty
    var selectedPageID: String?
    var selectedTab: WikiTab = .dashboard
    var searchText = ""
    var isLoading = false
    var statusMessage = "Abra uma pasta com Markdown ou Excalidraw."
    var errorMessage: String?
    var showSearchPalette = false
    var sourceMode: WikiSourceMode = .none

    var serverMode: PocketWikiServerMode = .localMac
    var serverStatus: PocketWikiServerStatus = .stopped
    var serverConfiguration = PocketWikiServerConfiguration.load()
    var serverLogs: [PocketWikiServerLogEntry] = []
    var remoteServerURLText = UserDefaults.standard.string(forKey: "PocketWikiMac.remoteServerURL") ?? "http://pocketwiki.local"
    var remoteConnectionMessage = "Nenhum servidor remoto conectado."

    private let folderPicker: WikiFolderPicker
    private let bookmarkStore: WikiBookmarkStore
    private let folderLoader: WikiFolderLoader
    private let indexer: WikiIndexer
    private let remoteClient: RemoteWikiClient
    private var currentSourceURL: URL?
    private var currentFiles: [WikiFile] = []
    private var localServer: PocketWikiHTTPServer?

    init(
        folderPicker: WikiFolderPicker = WikiFolderPicker(),
        bookmarkStore: WikiBookmarkStore = WikiBookmarkStore(),
        folderLoader: WikiFolderLoader = WikiFolderLoader(),
        indexer: WikiIndexer = WikiIndexer(),
        remoteClient: RemoteWikiClient = RemoteWikiClient()
    ) {
        self.folderPicker = folderPicker
        self.bookmarkStore = bookmarkStore
        self.folderLoader = folderLoader
        self.indexer = indexer
        self.remoteClient = remoteClient
    }

    var selectedPage: WikiPage? {
        index.page(id: selectedPageID)
    }

    var serverIndicatorTitle: String {
        serverStatus.title
    }

    var serverIndicatorDetail: String {
        serverStatus.detail
    }

    var remoteAIProxyBaseURL: String? {
        guard case .remoteServer(let url) = sourceMode else { return nil }
        return url.appendingPathComponent("api/ai").absoluteString
    }

    var canEditExcalidrawDocuments: Bool {
        switch sourceMode {
        case .localFolder, .localServer:
            return currentSourceURL != nil
        case .none, .remoteServer:
            return false
        }
    }

    var filteredPages: [WikiPage] {
        let query = searchText.lowercased().pocketTrimmed
        guard !query.isEmpty else { return index.pages }

        return index.pages.filter { page in
            page.title.lowercased().contains(query)
                || page.path.lowercased().contains(query)
                || page.summary.lowercased().contains(query)
                || page.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var searchResults: [WikiSearchResult] {
        let query = searchText.lowercased().pocketTrimmed
        guard !query.isEmpty else {
            return index.pages.prefix(30).map {
                WikiSearchResult(id: $0.id, pageID: $0.id, title: $0.title, path: $0.path, reason: "pagina")
            }
        }

        return index.pages.compactMap { page in
            if page.title.lowercased().contains(query) {
                return WikiSearchResult(id: page.id, pageID: page.id, title: page.title, path: page.path, reason: "titulo")
            }
            if page.path.lowercased().contains(query) {
                return WikiSearchResult(id: page.id, pageID: page.id, title: page.title, path: page.path, reason: "path")
            }
            if page.summary.lowercased().contains(query) {
                return WikiSearchResult(id: page.id, pageID: page.id, title: page.title, path: page.path, reason: "resumo")
            }
            if page.tags.contains(where: { $0.lowercased().contains(query) }) {
                return WikiSearchResult(id: page.id, pageID: page.id, title: page.title, path: page.path, reason: "tag")
            }
            return nil
        }
        .prefix(30)
        .map(\.self)
    }

    func openFolder() async {
        guard let url = folderPicker.pickFolder() else { return }
        await loadSource(url: url, persistBookmark: true)
    }

    func restoreLastSource() async {
        guard index.pages.isEmpty else { return }
        do {
            guard let bookmark = try bookmarkStore.restore() else { return }
            if bookmark.isStale {
                _ = try bookmarkStore.save(url: bookmark.url)
            }
            await loadSource(url: bookmark.url, persistBookmark: false)
        } catch {
            bookmarkStore.clear()
            errorMessage = "Nao consegui restaurar a pasta salva."
        }
    }

    func reloadCurrentSource() async {
        switch sourceMode {
        case .remoteServer:
            await connectRemoteServer()
        default:
            guard let currentSourceURL else { return }
            await loadSource(url: currentSourceURL, persistBookmark: false)
        }
    }

    func selectPage(_ id: String, tab: WikiTab = .reader) {
        guard index.page(id: id) != nil else { return }
        selectedPageID = id
        selectedTab = tab
        showSearchPalette = false
    }

    func selectTag(_ tag: String) {
        searchText = "#\(tag)"
    }

    func rawContent(for page: WikiPage) -> String? {
        currentFiles.first { $0.relativePath == page.path }?.content
    }

    func saveExcalidrawDocument(path: String, content: String) async throws {
        guard canEditExcalidrawDocuments else {
            throw ExcalidrawDocumentPersistenceError.readonlySource
        }
        guard isExcalidrawPath(path) else {
            throw ExcalidrawDocumentPersistenceError.invalidExtension
        }
        guard let currentSourceURL else {
            throw ExcalidrawDocumentPersistenceError.noLocalSource
        }

        let didStartScope = currentSourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                currentSourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destination = try WikiFilePathResolver.fileURL(root: currentSourceURL, relativePath: path)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        try reloadLocalSourceAfterWrite(root: currentSourceURL, selectingPath: path, status: "Excalidraw salvo")
    }

    func createExcalidrawDocument(near page: WikiPage?) async throws -> WikiPage? {
        guard canEditExcalidrawDocuments else {
            throw ExcalidrawDocumentPersistenceError.readonlySource
        }
        guard let currentSourceURL else {
            throw ExcalidrawDocumentPersistenceError.noLocalSource
        }

        let folder = page?.folder ?? ""
        let path = try nextExcalidrawPath(root: currentSourceURL, folder: folder)
        let content = Self.blankExcalidrawContent(title: WikiTextParser.baseName(path))

        let didStartScope = currentSourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                currentSourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destination = try WikiFilePathResolver.fileURL(root: currentSourceURL, relativePath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        try reloadLocalSourceAfterWrite(root: currentSourceURL, selectingPath: path, status: "Novo Excalidraw criado")
        return index.page(id: WikiTextParser.pathToSlug(path))
    }

    func exportPlainExcalidraw(content: String, suggestedName: String) async throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "excalidraw") ?? .json]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".excalidraw") ? suggestedName : "\(suggestedName).excalidraw"
        panel.title = "Salvar Excalidraw"
        panel.message = "Exporta a cena atual como arquivo .excalidraw JSON."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func startLocalServer() async {
        serverMode = .localMac
        serverStatus = .starting
        appendServerLog(PocketWikiServerLogEntry(level: .info, message: "Iniciando servidor desktop..."))

        localServer?.stop()
        let configuration = serverConfiguration
        let server = PocketWikiHTTPServer(
            configuration: configuration,
            sourceProvider: { [weak self] in
                await self?.servedSourceSnapshot(configuration: configuration) ?? .unavailable()
            },
            log: { [weak self] entry in
                Task { @MainActor in self?.appendServerLog(entry) }
            }
        )
        localServer = server

        do {
            let routes = try await server.start()
            serverStatus = .running(routes)
            if let urlText = routes.preferredURL, let url = URL(string: urlText) {
                sourceMode = .localServer(url)
            }
            await verifyLocalServer(routes: routes)
        } catch {
            localServer = nil
            serverStatus = .failed(error.localizedDescription)
            appendServerLog(PocketWikiServerLogEntry(level: .error, message: error.localizedDescription))
        }
    }

    func stopLocalServer() {
        localServer?.stop()
        localServer = nil
        serverStatus = .stopped
        if case .localServer = sourceMode {
            sourceMode = currentSourceURL.map { .localFolder($0) } ?? .none
        }
        appendServerLog(PocketWikiServerLogEntry(level: .info, message: "Servidor desktop desligado."))
    }

    func toggleLocalServer() async {
        if case .running = serverStatus {
            stopLocalServer()
        } else {
            await startLocalServer()
        }
    }

    func connectRemoteServer() async {
        serverMode = .external
        errorMessage = nil
        remoteConnectionMessage = "Conectando..."
        appendServerLog(PocketWikiServerLogEntry(level: .info, message: "Conectando em \(remoteServerURLText.pocketTrimmed)..."))

        do {
            let result = try await remoteClient.connect(to: remoteServerURLText)
            UserDefaults.standard.set(result.baseURL.absoluteString, forKey: "PocketWikiMac.remoteServerURL")
            remoteServerURLText = result.baseURL.absoluteString
            applyLoadedFiles(
                files: result.source.files,
                sourceName: result.source.rootName,
                loadIssues: [],
                selectedMode: .remoteServer(result.baseURL),
                status: "\(result.source.files.count) paginas remotas carregadas"
            )
            serverStatus = .remoteConnected(result.baseURL)
            remoteConnectionMessage = "Conectado em \(result.baseURL.absoluteString)"
            appendServerLog(PocketWikiServerLogEntry(level: .info, message: remoteConnectionMessage))
        } catch {
            serverStatus = .failed(error.localizedDescription)
            remoteConnectionMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            appendServerLog(PocketWikiServerLogEntry(level: .error, message: "Conexao remota falhou: \(error.localizedDescription)"))
        }
    }

    func disconnectRemoteServer() {
        guard case .remoteServer = sourceMode else { return }
        sourceMode = .none
        index = .empty
        currentFiles = []
        currentSourceURL = nil
        selectedPageID = nil
        selectedTab = .server
        serverStatus = localServer == nil ? .stopped : serverStatus
        remoteConnectionMessage = "Servidor remoto desconectado."
        appendServerLog(PocketWikiServerLogEntry(level: .info, message: remoteConnectionMessage))
    }

    private func loadSource(url: URL, persistBookmark: Bool) async {
        isLoading = true
        errorMessage = nil
        statusMessage = "Carregando \(url.lastPathComponent)..."

        let didStartScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            if persistBookmark {
                _ = try bookmarkStore.save(url: url)
            }

            let loaded = try folderLoader.loadFiles(from: url)
            applyLoadedFiles(
                files: loaded.files,
                sourceName: url.lastPathComponent,
                loadIssues: loaded.issues,
                selectedMode: .localFolder(url),
                status: "\(loaded.files.count) paginas carregadas"
            )
            currentSourceURL = url
        } catch {
            errorMessage = "Falha ao carregar \(url.lastPathComponent): \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func applyLoadedFiles(files: [WikiFile], sourceName: String, loadIssues: [String], selectedMode: WikiSourceMode, status: String) {
        let nextIndex = indexer.buildIndex(files: files, sourceName: sourceName, loadIssues: loadIssues)
        currentFiles = files
        index = nextIndex
        sourceMode = selectedMode
        selectedPageID = nextIndex.homePage?.id
        selectedTab = selectedMode == .none ? .server : .dashboard
        statusMessage = status
    }

    private func reloadLocalSourceAfterWrite(root: URL, selectingPath: String, status: String) throws {
        let loaded = try folderLoader.loadFiles(from: root)
        let selectedID = WikiTextParser.pathToSlug(selectingPath)
        let previousTab = selectedTab
        let previousMode = sourceMode
        let nextIndex = indexer.buildIndex(files: loaded.files, sourceName: root.lastPathComponent, loadIssues: loaded.issues)

        currentFiles = loaded.files
        index = nextIndex
        if case .localServer(let url) = previousMode {
            sourceMode = .localServer(url)
        } else {
            sourceMode = .localFolder(root)
        }
        selectedPageID = nextIndex.page(id: selectedID)?.id ?? nextIndex.homePage?.id
        selectedTab = selectedPageID == nil ? .dashboard : previousTab
        statusMessage = status
    }

    private func nextExcalidrawPath(root: URL, folder: String) throws -> String {
        for number in 1...999 {
            let suffix = number == 1 ? "" : " \(number)"
            let name = "Novo Desenho\(suffix).excalidraw"
            let path = folder.isEmpty ? name : "\(folder)/\(name)"
            let url = try WikiFilePathResolver.fileURL(root: root, relativePath: path)
            if !FileManager.default.fileExists(atPath: url.path) {
                return path
            }
        }
        throw ExcalidrawDocumentPersistenceError.fileExists
    }

    private func isExcalidrawPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".excalidraw") || lower.hasSuffix(".excalidraw.md")
    }

    private static func blankExcalidrawContent(title: String) -> String {
        """
        {
          "type": "excalidraw",
          "version": 2,
          "source": "https://github.com/irinery/PocketWiki",
          "elements": [],
          "appState": {
            "name": "\(title)",
            "theme": "dark",
            "viewBackgroundColor": "#ffffff"
          },
          "files": {}
        }

        """
    }

    private func servedSourceSnapshot(configuration: PocketWikiServerConfiguration) async -> PocketWikiServedSource {
        if !currentFiles.isEmpty {
            return PocketWikiServedSource(
                rootName: index.sourceName,
                source: sourceMode.title,
                configured: true,
                readonly: true,
                available: true,
                status: "ready",
                files: currentFiles
            )
        }

        let referenceURL = configuration.resolvedReferenceURL
        do {
            let loaded = try folderLoader.loadFiles(from: referenceURL)
            return PocketWikiServedSource(
                rootName: referenceURL.lastPathComponent,
                source: "env",
                configured: true,
                readonly: configuration.referenceReadonly,
                available: true,
                status: "ready",
                files: loaded.files
            )
        } catch {
            return .unavailable(rootName: referenceURL.lastPathComponent, status: "missing")
        }
    }

    private func appendServerLog(_ entry: PocketWikiServerLogEntry) {
        serverLogs.append(entry)
        if serverLogs.count > 240 {
            serverLogs.removeFirst(serverLogs.count - 240)
        }
    }

    private func verifyLocalServer(routes: PocketWikiRouteSnapshot) async {
        let localURLText = routes.local.first { $0.contains("127.0.0.1") } ?? routes.local.first
        guard let localURLText,
              let configURL = URL(string: localURLText)?.appendingPathComponent("api/config"),
              let webURL = URL(string: localURLText) else {
            return
        }

        do {
            var configRequest = URLRequest(url: configURL)
            configRequest.timeoutInterval = 3
            var webRequest = URLRequest(url: webURL)
            webRequest.timeoutInterval = 3

            let (_, configResponse) = try await URLSession.shared.data(for: configRequest)
            let configStatus = (configResponse as? HTTPURLResponse)?.statusCode ?? 0
            let (_, webResponse) = try await URLSession.shared.data(for: webRequest)
            let webStatus = (webResponse as? HTTPURLResponse)?.statusCode ?? 0

            if 200..<300 ~= configStatus, 200..<300 ~= webStatus {
                appendServerLog(PocketWikiServerLogEntry(level: .info, message: "Self-check OK em \(localURLText)."))
            } else {
                let message = "Self-check retornou web \(webStatus), api/config \(configStatus)."
                serverStatus = .failed(message)
                localServer?.stop()
                localServer = nil
                sourceMode = currentSourceURL.map { .localFolder($0) } ?? .none
                appendServerLog(PocketWikiServerLogEntry(level: .error, message: message))
            }
        } catch {
            let message = "Self-check local falhou: \(error.localizedDescription)"
            serverStatus = .failed(message)
            localServer?.stop()
            localServer = nil
            sourceMode = currentSourceURL.map { .localFolder($0) } ?? .none
            appendServerLog(PocketWikiServerLogEntry(level: .error, message: message))
        }
    }
}
