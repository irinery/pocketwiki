import Foundation

enum RemoteWikiClientError: Error, LocalizedError {
    case invalidBaseURL
    case badStatus(Int, String?)
    case unavailable
    case noIndexableFiles

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "URL invalida. Use algo como http://pocketwiki.local ou http://192.168.1.20:8787."
        case .badStatus(let status, let detail):
            if let detail, !detail.isEmpty {
                "Servidor respondeu HTTP \(status): \(detail)"
            } else {
                "Servidor respondeu HTTP \(status)."
            }
        case .unavailable:
            "Servidor respondeu, mas a wiki configurada esta indisponivel."
        case .noIndexableFiles:
            "Servidor conectado, mas nao retornou Markdown/Excalidraw indexavel."
        }
    }
}

struct RemoteWikiConnectionResult: Sendable {
    let baseURL: URL
    let config: RemoteWikiConfigPayload
    let source: PocketWikiServedSource
}

struct RemoteWikiConfigPayload: Decodable, Sendable {
    let referenceName: String?
    let referenceSource: String?
    let referenceConfigured: Bool?
    let referenceReadonly: Bool?
    let referenceAvailable: Bool?
    let referenceStatus: String?
    let lmStudioModel: String?
    let aiProxy: Bool?
}

struct RemoteWikiClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(to rawBaseURL: String) async throws -> RemoteWikiConnectionResult {
        let baseURL = try Self.normalizedBaseURL(rawBaseURL)
        let config = try await fetchConfig(baseURL: baseURL)
        let source = try await fetchSource(baseURL: baseURL)
        guard source.available else { throw RemoteWikiClientError.unavailable }
        guard !source.files.isEmpty else { throw RemoteWikiClientError.noIndexableFiles }
        return RemoteWikiConnectionResult(baseURL: baseURL, config: config, source: source)
    }

    func fetchConfig(baseURL: URL) async throws -> RemoteWikiConfigPayload {
        let data = try await data(for: baseURL.appendingPathComponent("api/config"))
        return try JSONDecoder().decode(RemoteWikiConfigPayload.self, from: data)
    }

    func fetchSource(baseURL: URL) async throws -> PocketWikiServedSource {
        let data = try await data(for: baseURL.appendingPathComponent("api/wiki/files"))
        return try Self.decodeWikiFilesResponse(data)
    }

    static func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let value = rawValue.pocketTrimmed
        guard !value.isEmpty, var components = URLComponents(string: value) else {
            throw RemoteWikiClientError.invalidBaseURL
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !components.path.isEmpty {
            components.path = "/" + components.path
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url, url.host(percentEncoded: false) != nil else {
            throw RemoteWikiClientError.invalidBaseURL
        }
        return url
    }

    static func decodeWikiFilesResponse(_ data: Data) throws -> PocketWikiServedSource {
        let decoded = try JSONDecoder().decode(RemoteWikiFilesResponse.self, from: data)
        let files = decoded.files.compactMap(\.wikiFile)
        return PocketWikiServedSource(
            rootName: decoded.rootName,
            source: decoded.source,
            configured: decoded.configured,
            readonly: decoded.readonly,
            available: decoded.available,
            status: decoded.status,
            files: files
        )
    }

    private func data(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw RemoteWikiClientError.badStatus(http.statusCode, Self.errorDetail(from: data))
        }
        return data
    }

    private static func errorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String {
                return error
            }
            if let message = object["message"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?.pocketTruncated(to: 500)
    }
}

private struct RemoteWikiFilesResponse: Decodable {
    let rootName: String
    let readonly: Bool
    let source: String
    let configured: Bool
    let available: Bool
    let status: String
    let files: [RemoteWikiFile]
}

private struct RemoteWikiFile: Decodable {
    let path: String
    let name: String?
    let size: Int
    let type: String?
    let updated: Double
    let content: String?

    var wikiFile: WikiFile? {
        guard let content, let kind = kind(for: path) else { return nil }
        return WikiFile(
            relativePath: path,
            sizeBytes: size,
            modifiedAt: Date(timeIntervalSince1970: updated / 1_000),
            content: content,
            kind: kind
        )
    }

    private func kind(for path: String) -> WikiFile.Kind? {
        let lower = path.lowercased()
        if lower.hasSuffix(".excalidraw.md") { return .excalidrawMarkdown }
        if lower.hasSuffix(".excalidraw") { return .excalidraw }
        if lower.hasSuffix(".md") { return .markdown }
        return nil
    }
}
