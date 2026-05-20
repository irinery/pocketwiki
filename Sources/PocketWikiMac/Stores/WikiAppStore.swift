import AppKit
import Foundation
import Observation

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

    private let folderPicker: WikiFolderPicker
    private let bookmarkStore: WikiBookmarkStore
    private let folderLoader: WikiFolderLoader
    private let indexer: WikiIndexer
    private var currentSourceURL: URL?

    init(
        folderPicker: WikiFolderPicker = WikiFolderPicker(),
        bookmarkStore: WikiBookmarkStore = WikiBookmarkStore(),
        folderLoader: WikiFolderLoader = WikiFolderLoader(),
        indexer: WikiIndexer = WikiIndexer()
    ) {
        self.folderPicker = folderPicker
        self.bookmarkStore = bookmarkStore
        self.folderLoader = folderLoader
        self.indexer = indexer
    }

    var selectedPage: WikiPage? {
        index.page(id: selectedPageID)
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
        guard let currentSourceURL else { return }
        await loadSource(url: currentSourceURL, persistBookmark: false)
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
            let nextIndex = indexer.buildIndex(files: loaded.files, sourceName: url.lastPathComponent, loadIssues: loaded.issues)
            index = nextIndex
            currentSourceURL = url
            selectedPageID = nextIndex.homePage?.id
            selectedTab = .dashboard
            statusMessage = "\(nextIndex.pages.count) paginas carregadas"
        } catch {
            errorMessage = "Falha ao carregar \(url.lastPathComponent): \(error.localizedDescription)"
        }

        isLoading = false
    }
}
