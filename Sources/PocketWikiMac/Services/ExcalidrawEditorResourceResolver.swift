import Foundation

enum ExcalidrawEditorResourceError: Error, LocalizedError {
    case invalidURL
    case invalidPath
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "URL invalida para recurso do Excalidraw."
        case .invalidPath:
            "Caminho invalido para recurso do Excalidraw."
        case .missingResource(let path):
            "Recurso do Excalidraw nao encontrado: \(path)"
        }
    }
}

struct ExcalidrawEditorResolvedResource: Equatable {
    let url: URL
    let data: Data
    let mimeType: String
}

struct ExcalidrawEditorResourceResolver {
    static let scheme = "pocketwiki-excalidraw"
    static let host = "bundle"

    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func resolve(_ url: URL) throws -> ExcalidrawEditorResolvedResource {
        let relativePath = try relativePath(for: url)
        let fileURL = try fileURL(forRelativePath: relativePath)
        let data = try Data(contentsOf: fileURL)
        return ExcalidrawEditorResolvedResource(
            url: fileURL,
            data: data,
            mimeType: Self.mimeType(for: relativePath)
        )
    }

    func relativePath(for url: URL) throws -> String {
        guard url.scheme == Self.scheme, url.host == Self.host else {
            throw ExcalidrawEditorResourceError.invalidURL
        }

        let rawPath = url.path.removingPercentEncoding ?? url.path
        let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = trimmed.isEmpty ? "index.html" : trimmed
        guard !relativePath.contains("\\") else {
            throw ExcalidrawEditorResourceError.invalidPath
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ExcalidrawEditorResourceError.invalidPath
        }

        return relativePath
    }

    func fileURL(forRelativePath relativePath: String) throws -> URL {
        let rootURL = root.standardizedFileURL
        let fileURL = rootURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard fileURL.path == rootURL.path || fileURL.path.hasPrefix(rootURL.path + "/") else {
            throw ExcalidrawEditorResourceError.invalidPath
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ExcalidrawEditorResourceError.missingResource(relativePath)
        }
        return fileURL
    }

    static func mimeType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html":
            return "text/html"
        case "js", "mjs":
            return "text/javascript"
        case "css":
            return "text/css"
        case "json", "map":
            return "application/json"
        case "woff2":
            return "font/woff2"
        case "woff":
            return "font/woff"
        case "ttf":
            return "font/ttf"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "ico":
            return "image/x-icon"
        case "wasm":
            return "application/wasm"
        case "md":
            return "text/markdown"
        default:
            return "application/octet-stream"
        }
    }
}
