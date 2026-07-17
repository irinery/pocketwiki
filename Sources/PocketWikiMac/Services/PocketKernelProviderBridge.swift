import Foundation
import Network

struct PocketKernelProviderRoute: Equatable, Sendable {
    var providerID: String
    var middlewareBaseURL: String
    var middlewareClientToken: String
    var projectID: String
    var profileID: String
    var modelID: String
    var reasoningEffort: String

    var normalizedProviderID: String {
        providerID.pocketTrimmed.lowercased() == "lmstudio" ? "lmstudio" : "openai"
    }

    var normalizedModelID: String {
        let fallback = normalizedProviderID == "openai" ? "gpt-5.5" : "local-model"
        return modelID.pocketTrimmed.pocketIfEmpty(fallback)
    }
}

struct PocketKernelProviderBridgeRuntime: Equatable, Sendable {
    let baseURL: URL
    let bearerToken: String
}

enum PocketKernelProviderBridgeError: Error, LocalizedError {
    case listenerUnavailable
    case invalidRequest
    case middlewareTokenMissing
    case responseEmpty

    var errorDescription: String? {
        switch self {
        case .listenerUnavailable: "bridge interno de provider não iniciou"
        case .invalidRequest: "request OpenAI-compatible inválido"
        case .middlewareTokenMissing: "bridge exige token interno do MiddlewareAuth"
        case .responseEmpty: "MiddlewareAuth respondeu sem outputText"
        }
    }
}

final class PocketKernelProviderBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PocketWiki.PocketKernelProviderBridge")
    private let lock = NSLock()
    private var configuration: PocketKernelProviderRoute?
    private var listener: NWListener?
    private var handlers: [UUID: PocketWikiHTTPConnectionHandler] = [:]
    private var runtime: PocketKernelProviderBridgeRuntime?

    func start(configuration: PocketKernelProviderRoute) async throws -> PocketKernelProviderBridgeRuntime {
        guard !configuration.middlewareClientToken.pocketTrimmed.isEmpty else {
            throw PocketKernelProviderBridgeError.middlewareTokenMissing
        }
        update(configuration: configuration)
        if let runtime = currentRuntime() {
            return runtime
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let startBox = PocketKernelProviderBridgeStartBox()
        let bearerToken = Self.randomToken()

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                guard let port = listener?.port,
                      let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
                    startBox.fail(PocketKernelProviderBridgeError.listenerUnavailable)
                    return
                }
                let runtime = PocketKernelProviderBridgeRuntime(baseURL: url, bearerToken: bearerToken)
                self?.setRuntime(runtime)
                startBox.succeed(runtime)
            case .failed(let error):
                startBox.fail(error)
            case .cancelled:
                self?.setRuntime(nil)
            default:
                break
            }
        }
        listener.start(queue: queue)
        return try await startBox.value()
    }

    func update(configuration: PocketKernelProviderRoute) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    func stop() {
        handlers.values.forEach { $0.cancel() }
        handlers.removeAll()
        listener?.cancel()
        listener = nil
        setRuntime(nil)
    }

    var isReady: Bool {
        currentRuntime() != nil && currentConfiguration() != nil
    }

    private func handle(_ connection: NWConnection) {
        let handler = PocketWikiHTTPConnectionHandler(
            connection: connection,
            maxBodyBytes: 2 * 1024 * 1024
        ) { [weak self] request in
            guard let self else { return Self.jsonError("bridge_unavailable", status: 503) }
            return await self.route(request)
        } onFinish: { [weak self] id in
            guard let server = self else { return }
            server.queue.async { server.handlers[id] = nil }
        }
        handlers[handler.id] = handler
        handler.start(queue: queue)
    }

    private func route(_ request: PocketWikiHTTPRequest) async -> PocketWikiHTTPResponse {
        guard let runtime = currentRuntime(),
              request.headers["authorization"] == "Bearer \(runtime.bearerToken)" else {
            return Self.jsonError("unauthorized", status: 401)
        }
        guard let configuration = currentConfiguration() else {
            return Self.jsonError("provider_not_configured", status: 503)
        }

        if request.method == "GET", request.urlPath == "/v1/models" {
            return Self.jsonResponse([
                "object": "list",
                "data": [[
                    "id": configuration.normalizedModelID,
                    "object": "model",
                    "owned_by": "middlewareauth"
                ]]
            ])
        }
        if request.method == "POST", request.urlPath == "/v1/chat/completions" {
            return await proxyChatCompletion(request.body, configuration: configuration)
        }
        return Self.jsonError("not_found", status: 404)
    }

    private func proxyChatCompletion(
        _ body: Data,
        configuration: PocketKernelProviderRoute
    ) async -> PocketWikiHTTPResponse {
        guard let input = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = input["messages"] as? [[String: Any]],
              !messages.isEmpty else {
            return Self.jsonError("invalid_chat_completion", status: 400)
        }

        var payload: [String: Any] = [
            "providerId": configuration.normalizedProviderID,
            "profileId": configuration.profileID.pocketTrimmed.pocketIfEmpty("default"),
            "model": (input["model"] as? String)?.pocketTrimmed.pocketIfEmpty(configuration.normalizedModelID)
                ?? configuration.normalizedModelID,
            "input": messages,
            "stream": false,
            "store": false
        ]
        if configuration.normalizedProviderID == "openai" {
            let effort = normalizedReasoningEffort(configuration.reasoningEffort)
            payload["intelligence"] = effort == "none" ? "instant" : "thinking"
            if effort != "none" {
                payload["reasoning"] = ["effort": effort, "summary": "auto"]
            }
        }

        do {
            let project = MiddlewareAuthEndpointPolicy.pathSegment(configuration.projectID, fallback: "acme")
            let url = try MiddlewareAuthEndpointPolicy.endpointURL(
                baseURL: configuration.middlewareBaseURL,
                path: "/v1/projects/\(project)/llm/responses"
            )
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("Bearer \(configuration.middlewareClientToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            guard 200..<300 ~= status else {
                return PocketWikiHTTPResponse(
                    status: status,
                    headers: ["Cache-Control": "no-store"],
                    body: data,
                    contentType: "application/json; charset=utf-8"
                )
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outputText = object["outputText"] as? String,
                  !outputText.pocketTrimmed.isEmpty else {
                return Self.jsonError("middlewareauth_response_empty", status: 502)
            }
            let usage = object["usage"] as? [String: Any] ?? [:]
            return Self.jsonResponse([
                "id": object["responseId"] as? String ?? "bridge-\(UUID().uuidString)",
                "object": "chat.completion",
                "model": payload["model"] as? String ?? configuration.normalizedModelID,
                "choices": [[
                    "index": 0,
                    "message": ["role": "assistant", "content": outputText],
                    "finish_reason": "stop"
                ]],
                "usage": [
                    "prompt_tokens": usage["inputTokens"] as? Int ?? 0,
                    "completion_tokens": usage["outputTokens"] as? Int ?? 0,
                    "total_tokens": usage["totalTokens"] as? Int ?? 0
                ]
            ])
        } catch {
            return Self.jsonError("middlewareauth_bridge_failed", status: 502)
        }
    }

    private func normalizedReasoningEffort(_ rawValue: String) -> String {
        switch rawValue.pocketTrimmed.lowercased() {
        case "none", "off", "instant", "disabled": "none"
        case "low", "baixo": "low"
        case "high", "alto": "high"
        default: "medium"
        }
    }

    private func currentConfiguration() -> PocketKernelProviderRoute? {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    private func currentRuntime() -> PocketKernelProviderBridgeRuntime? {
        lock.lock()
        defer { lock.unlock() }
        return runtime
    }

    private func setRuntime(_ runtime: PocketKernelProviderBridgeRuntime?) {
        lock.lock()
        self.runtime = runtime
        lock.unlock()
    }

    private static func jsonResponse(_ object: [String: Any], status: Int = 200) -> PocketWikiHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return PocketWikiHTTPResponse(
            status: status,
            headers: ["Cache-Control": "no-store"],
            body: body,
            contentType: "application/json; charset=utf-8"
        )
    }

    private static func jsonError(_ code: String, status: Int) -> PocketWikiHTTPResponse {
        jsonResponse(["error": ["code": code, "message": code]], status: status)
    }

    private static func randomToken() -> String {
        (UUID().uuidString + UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
    }
}

private final class PocketKernelProviderBridgeStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PocketKernelProviderBridgeRuntime, Error>?
    private var result: Result<PocketKernelProviderBridgeRuntime, Error>?

    func value() async throws -> PocketKernelProviderBridgeRuntime {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func succeed(_ runtime: PocketKernelProviderBridgeRuntime) {
        complete(.success(runtime))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<PocketKernelProviderBridgeRuntime, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
