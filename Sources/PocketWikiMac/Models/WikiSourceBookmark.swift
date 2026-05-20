import Foundation

struct WikiSourceBookmark: Hashable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let bookmarkData: Data
    let isStale: Bool
}
