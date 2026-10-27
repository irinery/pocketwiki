import Foundation

struct PocketMemoryHookEvent: Codable, Hashable, Sendable {
    let ingestKey: String
    let event: String
    let sessionID: UUID
    let cwd: String
    let prompt: String?
    let message: String?
    let providerID: String?
    let modelID: String?
    let endpoint: String
}

struct PocketMemoryConfiguration: Hashable, Sendable {
    let endpoint: URL
    let authToken: String

    init?(serverURL: String, authToken: String) {
        guard authToken.pocketTrimmed.count >= 16,
              var components = URLComponents(string: serverURL.pocketTrimmed),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [prefix, "api/memory"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let endpoint = components.url else { return nil }
        self.endpoint = endpoint
        self.authToken = authToken.pocketTrimmed
    }
}

enum PocketMemoryClientError: Error, LocalizedError {
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code): "Memoria PocketWiki respondeu HTTP \(code)."
        case .invalidResponse: "Resposta invalida da memoria PocketWiki."
        }
    }
}

/// Cliente da API HTTP interna do PocketWiki. Nenhum servidor MCP externo e necessario.
actor PocketMemoryClient {
    private let configuration: PocketMemoryConfiguration
    private let session: URLSession

    init(configuration: PocketMemoryConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func recall(question: String, maxCharacters: Int = 5_000) async throws -> String {
        let response = try await post("recall", body: ["question": String(question.prefix(2_000))])
        guard let context = response["context"] as? String else { throw PocketMemoryClientError.invalidResponse }
        return String(context.prefix(maxCharacters))
    }

    func deliverHooks(_ events: [PocketMemoryHookEvent]) async throws -> Set<String> {
        guard !events.isEmpty else { return [] }
        guard events.allSatisfy({ $0.endpoint == configuration.endpoint.absoluteString }) else {
            throw PocketMemoryClientError.invalidResponse
        }
        let batch: [[String: Any]] = events.map { item in
            var body: [String: Any] = [
                "event": item.event,
                "session_id": item.sessionID.uuidString.lowercased(),
                "ingest_key": item.ingestKey
            ]
            if let prompt = item.prompt { body["prompt"] = String(prompt.prefix(8_000)) }
            if let message = item.message { body["message"] = String(message.prefix(8_000)) }
            if let provider = item.providerID { body["provider_id"] = provider }
            if let model = item.modelID { body["model_id"] = model }
            return body
        }
        let response = try await post("capture", body: ["events": batch])
        guard let keys = response["accepted_keys"] as? [String] else { throw PocketMemoryClientError.invalidResponse }
        return Set(keys)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PocketMemoryClientError.invalidResponse }
        guard 200..<300 ~= http.statusCode else { throw PocketMemoryClientError.http(http.statusCode) }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PocketMemoryClientError.invalidResponse
        }
        return result
    }
}
