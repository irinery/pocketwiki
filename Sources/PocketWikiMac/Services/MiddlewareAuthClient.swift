import Foundation

enum MiddlewareAuthClientError: Error, LocalizedError {
    case invalidEndpoint
    case missingClientToken
    case missingLMStudioAPIKey
    case missingLoginSession
    case badStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Endpoint MiddlewareAuth invalido."
        case .missingClientToken:
            "MiddlewareAuth exige MIDDLEWARE_CLIENT_TOKEN."
        case .missingLMStudioAPIKey:
            "Informe a API key do LM Studio para registrar o provider."
        case .missingLoginSession:
            "Sessao de login OpenAI nao informada."
        case .badStatus(let status, let detail):
            if let detail, !detail.isEmpty {
                "MiddlewareAuth respondeu HTTP \(status): \(detail)"
            } else {
                "MiddlewareAuth respondeu HTTP \(status)."
            }
        }
    }
}

enum MiddlewareAuthEndpointPolicy {
    static let defaultBaseURL = "http://127.0.0.1:18787"

    static func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let value = rawValue.pocketTrimmed.isEmpty ? defaultBaseURL : rawValue.pocketTrimmed
        guard let rawURL = URL(string: value),
              LocalAIEndpointPolicy.isAllowedLocalBaseURL(rawURL),
              var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
            throw MiddlewareAuthClientError.invalidEndpoint
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !components.path.isEmpty {
            components.path = "/" + components.path
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw MiddlewareAuthClientError.invalidEndpoint }
        return url
    }

    static func endpointURL(baseURL rawValue: String, path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let baseURL = try normalizedBaseURL(rawValue)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MiddlewareAuthClientError.invalidEndpoint
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw MiddlewareAuthClientError.invalidEndpoint }
        return url
    }

    static func pathSegment(_ rawValue: String, fallback: String) -> String {
        let value = rawValue.pocketTrimmed.pocketIfEmpty(fallback)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? fallback
    }
}

struct MiddlewareAuthOpenAIStatus: Decodable, Sendable {
    let authenticated: Bool
    let providerId: String?
    let projectId: String?
    let profileId: String?
    let accountId: String?
    let email: String?
    let chatgptPlanType: String?
    let expires: Int64?

    var summary: String {
        if authenticated {
            let account = email?.pocketTrimmed.pocketIfEmpty(accountId?.pocketTrimmed ?? "") ?? accountId?.pocketTrimmed ?? ""
            let plan = chatgptPlanType?.pocketTrimmed ?? ""
            let suffix = [account, plan].filter { !$0.isEmpty }.joined(separator: " · ")
            return suffix.isEmpty ? "OpenAI autenticado no MiddlewareAuth." : "OpenAI autenticado: \(suffix)"
        }
        return "Faça login para conectar sua conta OpenAI."
    }
}

struct MiddlewareAuthOpenAILoginStart: Decodable, Sendable {
    let loginSessionId: String
    let authUrl: String?
    let verificationUrl: String?
    let userCode: String?
    let expiresAt: Int64?

    var summary: String {
        if let userCode, !userCode.pocketTrimmed.isEmpty {
            return "Login iniciado. Use o codigo \(userCode.pocketTrimmed)."
        }
        if authUrl?.pocketTrimmed.isEmpty == false || verificationUrl?.pocketTrimmed.isEmpty == false {
            return "Login iniciado no navegador."
        }
        return "Login OpenAI iniciado."
    }
}

struct MiddlewareAuthOpenAILoginStatus: Decodable, Sendable {
    let loginSessionId: String
    let projectId: String?
    let profileId: String?
    let mode: String?
    let status: String?
    let expiresAt: Int64?
    let completedAt: Int64?

    var summary: String {
        switch status?.pocketTrimmed.lowercased() {
        case "completed":
            return "Login OpenAI concluido."
        case "expired":
            return "Sessao de login OpenAI expirada."
        case "failed":
            return "Login OpenAI falhou."
        default:
            return "Login OpenAI pendente."
        }
    }
}

struct MiddlewareAuthLMStudioStatus: Decodable, Sendable {
    let authenticated: Bool
    let providerId: String?
    let projectId: String?
    let profileId: String?
    let baseUrl: String?
    let accountId: String?
    let modelCount: Int?
    let savedAt: Int64?

    var summary: String {
        if authenticated {
            let provider = providerId ?? "lmstudio"
            let profile = profileId ?? "default"
            let modelText = modelCount.map { " · \($0) modelo(s)" } ?? ""
            return "\(provider) autenticado em \(profile)\(modelText)"
        }
        return "LM Studio ainda nao autenticado no MiddlewareAuth."
    }
}

struct MiddlewareAuthClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func openAIStatus(
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        profileID: String
    ) async throws -> MiddlewareAuthOpenAIStatus {
        let cleanToken = clientToken.pocketTrimmed
        guard !cleanToken.isEmpty else { throw MiddlewareAuthClientError.missingClientToken }

        var request = URLRequest(url: try MiddlewareAuthEndpointPolicy.endpointURL(
            baseURL: middlewareBaseURL,
            path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/openai/status",
            queryItems: [URLQueryItem(name: "profileId", value: profileID.pocketTrimmed.pocketIfEmpty("default"))]
        ))
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await send(request)
    }

    func startOpenAILogin(
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        profileID: String,
        mode: String = "device_code"
    ) async throws -> MiddlewareAuthOpenAILoginStart {
        let cleanToken = clientToken.pocketTrimmed
        guard !cleanToken.isEmpty else { throw MiddlewareAuthClientError.missingClientToken }

        var request = URLRequest(url: try MiddlewareAuthEndpointPolicy.endpointURL(
            baseURL: middlewareBaseURL,
            path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/openai/login"
        ))
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(OpenAILoginStartRequest(
            profileId: profileID.pocketTrimmed.pocketIfEmpty("default"),
            mode: mode.pocketTrimmed.pocketIfEmpty("device_code")
        ))

        return try await send(request)
    }

    func openAILoginStatus(
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        loginSessionID: String
    ) async throws -> MiddlewareAuthOpenAILoginStatus {
        let cleanToken = clientToken.pocketTrimmed
        guard !cleanToken.isEmpty else { throw MiddlewareAuthClientError.missingClientToken }
        guard !loginSessionID.pocketTrimmed.isEmpty else { throw MiddlewareAuthClientError.missingLoginSession }

        var request = URLRequest(url: try MiddlewareAuthEndpointPolicy.endpointURL(
            baseURL: middlewareBaseURL,
            path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/openai/login-sessions/\(MiddlewareAuthEndpointPolicy.pathSegment(loginSessionID, fallback: ""))"
        ))
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await send(request)
    }

    func configureLMStudio(
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        profileID: String,
        lmStudioBaseURL: String,
        apiKey: String
    ) async throws -> MiddlewareAuthLMStudioStatus {
        let cleanToken = clientToken.pocketTrimmed
        guard !cleanToken.isEmpty else { throw MiddlewareAuthClientError.missingClientToken }
        guard !apiKey.pocketTrimmed.isEmpty else { throw MiddlewareAuthClientError.missingLMStudioAPIKey }

        var request = URLRequest(url: try MiddlewareAuthEndpointPolicy.endpointURL(
            baseURL: middlewareBaseURL,
            path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/lmstudio/api-key"
        ))
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(LMStudioAPIKeyRequest(
            profileId: profileID.pocketTrimmed.pocketIfEmpty("default"),
            baseUrl: lmStudioBaseURL.pocketTrimmed.pocketIfEmpty("http://127.0.0.1:1234"),
            apiKey: apiKey
        ))

        return try await send(request)
    }

    func lmStudioStatus(
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        profileID: String
    ) async throws -> MiddlewareAuthLMStudioStatus {
        let cleanToken = clientToken.pocketTrimmed
        guard !cleanToken.isEmpty else { throw MiddlewareAuthClientError.missingClientToken }

        var request = URLRequest(url: try MiddlewareAuthEndpointPolicy.endpointURL(
            baseURL: middlewareBaseURL,
            path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/lmstudio/status",
            queryItems: [URLQueryItem(name: "profileId", value: profileID.pocketTrimmed.pocketIfEmpty("default"))]
        ))
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw MiddlewareAuthClientError.badStatus(http.statusCode, Self.errorDetail(from: data))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func errorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                return [error["code"], error["message"]]
                    .compactMap { $0 as? String }
                    .filter { !$0.isEmpty }
                    .joined(separator: ": ")
            }
            if let code = object["code"] as? String {
                return [code, object["message"] as? String].compactMap { $0 }.joined(separator: ": ")
            }
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

private struct OpenAILoginStartRequest: Encodable {
    let profileId: String
    let mode: String
}

private struct LMStudioAPIKeyRequest: Encodable {
    let profileId: String
    let baseUrl: String
    let apiKey: String
}
