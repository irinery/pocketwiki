import Foundation

struct WikiFile: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case markdown
        case excalidraw
        case excalidrawMarkdown
    }

    let id: String
    let relativePath: String
    let name: String
    let sizeBytes: Int
    let modifiedAt: Date
    let content: String
    let kind: Kind

    init(relativePath: String, sizeBytes: Int, modifiedAt: Date, content: String, kind: Kind) {
        self.id = WikiTextParser.pathToSlug(relativePath)
        self.relativePath = relativePath
        self.name = WikiTextParser.baseName(relativePath)
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.content = content
        self.kind = kind
    }
}
