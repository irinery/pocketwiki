import Foundation

struct WikiBookmarkStore {
    private let key = "PocketWikiMac.sourceBookmark"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(url: URL) throws -> WikiSourceBookmark {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
        return WikiSourceBookmark(
            id: url.path,
            url: url,
            displayName: url.lastPathComponent,
            bookmarkData: data,
            isStale: false
        )
    }

    func restore() throws -> WikiSourceBookmark? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return WikiSourceBookmark(
            id: url.path,
            url: url,
            displayName: url.lastPathComponent,
            bookmarkData: data,
            isStale: stale
        )
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
