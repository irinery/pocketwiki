import Foundation

struct AIMemoryHookEvent: Codable, Hashable, Sendable {
    let ingestKey: String
    let event: String
    let sessionID: UUID
    let cwd: String
    let prompt: String?
    let message: String?
    let endpoint: String
    let workspace: String
    let project: String
}

struct AIMemoryConfiguration: Hashable, Sendable {
    let endpoint: URL
    let workspace: String
    let project: String
    let authToken: String

    init?(serverURL: String, workspace: String, project: String, authToken: String) {
        guard !serverURL.pocketTrimmed.isEmpty,
              !workspace.pocketTrimmed.isEmpty,
              !project.pocketTrimmed.isEmpty,
              var components = URLComponents(string: serverURL.pocketTrimmed),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return nil }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.hasSuffix("/mcp") || path == "mcp"
            ? "/" + path
            : "/" + [path, "mcp"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let endpoint = components.url else { return nil }
        self.endpoint = endpoint
        self.workspace = workspace.pocketTrimmed
        self.project = project.pocketTrimmed
        self.authToken = authToken.pocketTrimmed
    }
}

enum AIMemoryClientError: Error, LocalizedError {
    case http(Int)
    case invalidResponse
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): "ai-memory respondeu HTTP \(code)."
        case .invalidResponse: "Resposta MCP invalida do ai-memory."
        case .rpc(let message): "ai-memory: \(message)"
        }
    }
}

/// Native MCP client for ai-memory's stateless Streamable HTTP endpoint.
actor AIMemoryClient {
    private let configuration: AIMemoryConfiguration
    private let session: URLSession
    private var initialized = false

    init(configuration: AIMemoryConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func recall(question: String, maxCharacters: Int = 5_000) async throws -> String {
        let response = try await callTool("memory_query", arguments: [
            "workspace": configuration.workspace,
            "project": configuration.project,
            "query": String(question.prefix(500)),
            "limit": 3
        ])
        let hits = response["hits"] as? [[String: Any]] ?? []
        var blocks: [String] = []
        var remaining = maxCharacters

        for hit in hits.prefix(3) where remaining > 0 {
            guard let path = hit["path"] as? String, !path.isEmpty else { continue }
            let title = hit["title"] as? String ?? path
            let snippet = (hit["snippet"] as? String ?? "")
                .replacingOccurrences(of: "<mark>", with: "")
                .replacingOccurrences(of: "</mark>", with: "")
            let body = (try? await callTool("memory_read_page", arguments: [
                "workspace": configuration.workspace,
                "project": configuration.project,
                "path": path
            ]))?["body"] as? String
            let content = (body?.pocketTrimmed.isEmpty == false ? body : nil) ?? snippet
            let block = "Fonte ai-memory: \(path)\nTitulo: \(title)\n\(content)"
            let fitted = String(block.prefix(remaining))
            guard !fitted.isEmpty else { continue }
            blocks.append(fitted)
            remaining -= fitted.count
        }
        return blocks.joined(separator: "\n\n---\n\n")
    }

    func deliverHooks(_ events: [AIMemoryHookEvent]) async throws -> Set<String> {
        guard !events.isEmpty else { return [] }
        let hookURL = configuration.endpoint.deletingLastPathComponent().appendingPathComponent("hook/batch")
        let batch: [[String: Any]] = events.compactMap { item in
            guard item.endpoint == configuration.endpoint.absoluteString,
                  item.workspace == configuration.workspace,
                  item.project == configuration.project,
                  var components = URLComponents(string: "/hook") else { return nil }
            components.queryItems = [
                URLQueryItem(name: "event", value: item.event),
                URLQueryItem(name: "agent", value: "other"),
                URLQueryItem(name: "workspace", value: item.workspace),
                URLQueryItem(name: "project", value: item.project),
                URLQueryItem(name: "extension", value: "pocketwiki"),
                URLQueryItem(name: "source_event", value: item.event),
                URLQueryItem(name: "ingest_key", value: item.ingestKey)
            ]
            var body: [String: Any] = [
                "session_id": item.sessionID.uuidString.lowercased(),
                "cwd": item.cwd
            ]
            if let prompt = item.prompt { body["prompt"] = String(prompt.prefix(8_000)) }
            if let message = item.message { body["message"] = String(message.prefix(8_000)) }
            return ["url": components.string ?? "", "body": body]
        }
        guard batch.count == events.count else { throw AIMemoryClientError.invalidResponse }

        var request = URLRequest(url: hookURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.authToken.isEmpty {
            request.setValue("Bearer \(configuration.authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: batch)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIMemoryClientError.invalidResponse
        }
        let acceptedIndices = result["accepted_indices"] as? [Int]
            ?? Array(0..<(min(result["accepted"] as? Int ?? 0, events.count)))
        let accepted = Set(acceptedIndices.filter { events.indices.contains($0) }.map { events[$0].ingestKey })
        if !(200..<300 ~= http.statusCode), accepted.isEmpty {
            throw AIMemoryClientError.http(http.statusCode)
        }
        return accepted
    }

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        if !initialized {
            _ = try await rpc(method: "initialize", params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: String],
                "clientInfo": ["name": "pocketwiki", "version": "1.0"]
            ])
            initialized = true
        }
        let envelope = try await rpc(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])
        guard let result = envelope["result"] as? [String: Any],
              result["isError"] as? Bool != true else {
            throw AIMemoryClientError.rpc("ferramenta \(name) falhou")
        }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        guard let content = result["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first,
              let data = text.data(using: .utf8),
              let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIMemoryClientError.invalidResponse
        }
        return decoded
    }

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !configuration.authToken.isEmpty {
            request.setValue("Bearer \(configuration.authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIMemoryClientError.invalidResponse }
        guard 200..<300 ~= http.statusCode else { throw AIMemoryClientError.http(http.statusCode) }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIMemoryClientError.invalidResponse
        }
        if let error = envelope["error"] as? [String: Any] {
            throw AIMemoryClientError.rpc(error["message"] as? String ?? "erro JSON-RPC")
        }
        return envelope
    }
}
