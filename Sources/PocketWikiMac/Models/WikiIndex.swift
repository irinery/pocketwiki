import Foundation

struct WikiIndex: Sendable {
    let sourceName: String
    let pages: [WikiPage]
    let pageByID: [String: WikiPage]
    let missingLinks: [String: [String]]
    let tagIndex: [String: [String]]
    let generatedAt: Date
    let loadIssues: [String]

    static let empty = WikiIndex(
        sourceName: "nenhuma wiki carregada",
        pages: [],
        missingLinks: [:],
        tagIndex: [:],
        generatedAt: Date(timeIntervalSince1970: 0),
        loadIssues: []
    )

    init(sourceName: String, pages: [WikiPage], missingLinks: [String: [String]], tagIndex: [String: [String]], generatedAt: Date = Date(), loadIssues: [String] = []) {
        self.sourceName = sourceName
        self.pages = pages.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        self.pageByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        self.missingLinks = missingLinks
        self.tagIndex = tagIndex.mapValues { $0.sorted() }
        self.generatedAt = generatedAt
        self.loadIssues = loadIssues
    }

    func page(id: String?) -> WikiPage? {
        guard let id else { return nil }
        return pageByID[id]
    }

    var homePage: WikiPage? {
        pageByID["index"] ?? pageByID["home"] ?? pageByID["readme"] ?? pages.sorted { $0.path < $1.path }.first
    }
}
