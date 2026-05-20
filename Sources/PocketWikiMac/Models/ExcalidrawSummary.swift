import Foundation

struct ExcalidrawSummary: Identifiable, Hashable, Sendable {
    struct Stats: Hashable, Sendable {
        let elements: Int
        let textElements: Int
        let links: Int
    }

    let id: String
    let slug: String
    let path: String
    let title: String
    let texts: [String]
    let links: [WikiLink]
    let relationHints: [String]
    let stats: Stats
    let fallbackReason: String?
}
