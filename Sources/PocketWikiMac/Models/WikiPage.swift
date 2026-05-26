import Foundation

struct WikiHeading: Identifiable, Hashable, Sendable {
    let id: String
    let level: Int
    let text: String
}

struct WikiPage: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case markdown
        case excalidraw
    }

    let id: String
    let slug: String
    let path: String
    let title: String
    let folder: String
    let content: String
    let summary: String
    let tags: [String]
    let links: [WikiLink]
    var outlinks: [WikiResolvedLink]
    var backlinks: [String]
    var missingLinks: [WikiLink]
    let headings: [WikiHeading]
    let updatedAt: Date?
    let wordCount: Int
    let readingMinutes: Int
    let isSpecial: Bool
    let sizeBytes: Int
    let kind: Kind
    let excalidraw: ExcalidrawSummary?

    var healthClass: WikiHealthClass {
        if !missingLinks.isEmpty { return .bad }
        if summary.isEmpty || (outlinks.isEmpty && backlinks.isEmpty) { return .warn }
        return .good
    }

    var connectivityScore: Double {
        Double(outlinks.count) + Double(backlinks.count) * 1.5 + Double(tags.count) * 0.3
    }
}

enum WikiHealthClass: String, Codable, Sendable {
    case good
    case warn
    case bad
}
