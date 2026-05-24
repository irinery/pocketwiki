import Foundation

struct PocketWikiFilesPayload: Encodable, Sendable {
    let rootName: String
    let readonly: Bool
    let source: String
    let configured: Bool
    let available: Bool
    let status: String
    let files: [PocketWikiFilePayload]

    init(source: PocketWikiServedSource) {
        rootName = source.rootName
        readonly = source.readonly
        self.source = source.source
        configured = source.configured
        available = source.available
        status = source.status
        files = source.files.map(PocketWikiFilePayload.init(file:))
    }
}

struct PocketWikiFilePayload: Encodable, Sendable {
    let path: String
    let name: String
    let size: Int
    let type: String
    let updated: Double
    let content: String?

    init(file: WikiFile) {
        path = file.relativePath
        name = file.name
        size = file.sizeBytes
        type = PocketWikiContentTypes.contentType(for: file.relativePath)
        updated = file.modifiedAt.timeIntervalSince1970 * 1_000
        content = file.content
    }
}

enum PocketWikiContentTypes {
    static func contentType(for file: String) -> String {
        let lower = file.lowercased()
        if lower.hasSuffix(".excalidraw") { return "application/vnd.excalidraw+json" }
        if lower.hasSuffix(".canvas") { return "application/vnd.obsidian.canvas+json" }
        if lower.hasSuffix(".drawio") { return "application/vnd.jgraph.mxfile" }
        if lower.hasSuffix(".md") { return "text/markdown; charset=utf-8" }
        if lower.hasSuffix(".ico") { return "image/x-icon" }
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".svg") { return "image/svg+xml" }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if lower.hasSuffix(".js") { return "application/javascript; charset=utf-8" }
        if lower.hasSuffix(".json") { return "application/json; charset=utf-8" }
        if lower.hasSuffix(".webmanifest") { return "application/manifest+json; charset=utf-8" }
        if lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") { return "text/yaml; charset=utf-8" }
        if lower.hasSuffix(".txt") { return "text/plain; charset=utf-8" }
        return "application/octet-stream"
    }
}
