import Foundation
import Network

enum PocketWikiHTTPServerError: Error, LocalizedError {
    case invalidPort(Int)
    case requestTooLarge
    case malformedRequest
    case missingWebRoot
    case invalidUpstream

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Porta invalida: \(port)."
        case .requestTooLarge:
            "Request grande demais."
        case .malformedRequest:
            "Request HTTP invalido."
        case .missingWebRoot:
            "Assets web nao encontrados no bundle do app."
        case .invalidUpstream:
            "Endpoint upstream invalido."
        }
    }
}

final class PocketWikiHTTPServer: @unchecked Sendable {
    typealias SourceProvider = @Sendable () async -> PocketWikiServedSource
    typealias Logger = @Sendable (PocketWikiServerLogEntry) -> Void

    private let configuration: PocketWikiServerConfiguration
    private let sourceProvider: SourceProvider
    private let log: Logger
    private let queue = DispatchQueue(label: "PocketWiki.HTTPServer")
    private let mdnsResponder: PocketWikiMDNSResponder
    private let solutionIngestion: PocketWikiSolutionIngestion
    private var listener: NWListener?
    private var webRoot: URL?
    private var handlers: [UUID: PocketWikiHTTPConnectionHandler] = [:]

    init(
        configuration: PocketWikiServerConfiguration,
        sourceProvider: @escaping SourceProvider,
        log: @escaping Logger
    ) {
        self.configuration = configuration
        self.sourceProvider = sourceProvider
        self.log = log
        self.mdnsResponder = PocketWikiMDNSResponder(log: log)
        self.solutionIngestion = PocketWikiSolutionIngestion(writeToken: configuration.writeToken)
    }

    func start() async throws -> PocketWikiRouteSnapshot {
        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            throw PocketWikiHTTPServerError.invalidPort(configuration.port)
        }

        let root = try PocketWikiWebRuntimeResolver.webRoot()
        webRoot = root

        let parameters = NWParameters.tcp
        if let localEndpoint = localEndpoint() {
            parameters.requiredLocalEndpoint = localEndpoint
        }

        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener
        let routes = configuration.routes
        let startBox = ListenerStartBox()

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if self?.configuration.mdnsEnabled == true {
                    self?.mdnsResponder.start(hosts: self?.configuration.publicHosts ?? [], port: self?.configuration.port ?? 0)
                }
                self?.log(PocketWikiServerLogEntry(level: .info, message: "Servidor ligado em \(routes.local.first ?? "localhost")"))
                startBox.succeed(routes)
            case .failed(let error):
                self?.log(PocketWikiServerLogEntry(level: .error, message: "Servidor falhou: \(error.localizedDescription)"))
                startBox.fail(error)
            case .cancelled:
                self?.log(PocketWikiServerLogEntry(level: .info, message: "Servidor desligado."))
            default:
                break
            }
        }

        listener.start(queue: queue)
        return try await startBox.value()
    }

    func stop() {
        mdnsResponder.stop()
        handlers.values.forEach { $0.cancel() }
        handlers.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func localEndpoint() -> NWEndpoint? {
        let host = configuration.bindHost.pocketTrimmed.lowercased()
        guard !host.isEmpty, host != "0.0.0.0", host != "::" else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: .any)
    }

    private func handle(_ connection: NWConnection) {
        let handler = PocketWikiHTTPConnectionHandler(
            connection: connection,
            maxBodyBytes: configuration.writeMaxBytes
        ) { [weak self] request in
            guard let self else {
                return PocketWikiHTTPResponse(status: 503, body: Data("server_unavailable".utf8), contentType: "text/plain; charset=utf-8")
            }
            return await self.route(request)
        } onFinish: { [weak self] id in
            guard let server = self else { return }
            server.queue.async {
                server.handlers[id] = nil
            }
        }
        handlers[handler.id] = handler
        handler.start(queue: queue)
    }

    private func route(_ request: PocketWikiHTTPRequest) async -> PocketWikiHTTPResponse {
        let path = request.urlPath
        if path == "/" || path == "/wiki-cockpit.html" {
            logRequest(request)
            return fileResponse("wiki-cockpit.html", contentType: "text/html; charset=utf-8", headOnly: request.isHead)
        }
        if path == "/offline.html" {
            return fileResponse("offline.html", contentType: "text/html; charset=utf-8", headers: ["Cache-Control": "no-cache"], headOnly: request.isHead)
        }
        if path == "/manifest.webmanifest" {
            return fileResponse("manifest.webmanifest", contentType: "application/manifest+json; charset=utf-8", headers: ["Cache-Control": "no-cache"], headOnly: request.isHead)
        }
        if path == "/sw.js" {
            return fileResponse("sw.js", contentType: "application/javascript; charset=utf-8", headers: ["Cache-Control": "no-cache"], headOnly: request.isHead)
        }
        if path == "/favicon.ico" || path == "/favicon.png" {
            return fileResponse(String(path.dropFirst()), contentType: PocketWikiContentTypes.contentType(for: path), headers: ["Cache-Control": "no-cache"], optional: true, headOnly: request.isHead)
        }
        if path.hasPrefix("/assets/") {
            return assetResponse(path, headOnly: request.isHead)
        }
        if request.method == "GET", path == "/api/config" {
            logRequest(request)
            return await jsonResponse(configPayload())
        }
        if request.method == "GET", path == "/api/routes" {
            logRequest(request)
            return jsonResponse(configuration.routes)
        }
        if request.method == "GET", path == "/api/wiki/files" {
            logRequest(request)
            let source = await sourceProvider()
            return jsonResponse(Self.filesPayload(source))
        }
        if request.method == "GET", path == "/api/prompts/wiki-review" {
            logRequest(request)
            if let url = PocketWikiResourceBundle.url(forResource: "wiki-review", withExtension: "md"),
               let data = try? Data(contentsOf: url) {
                return PocketWikiHTTPResponse(status: 200, body: request.isHead ? Data() : data, contentType: "text/markdown; charset=utf-8")
            }
            return notFound()
        }
        if request.method == "PUT", let solutionID = solutionID(from: path) {
            logRequest(request)
            let source = await sourceProvider()
            return await solutionIngestion.handle(
                request: request,
                solutionID: solutionID,
                source: source,
                configuredRoot: configuration.resolvedReferenceURL
            )
        }
        if request.method == "POST", path == "/api/kernel/query" {
            logRequest(request)
            return await proxyPocketKernel(body: request.body)
        }
        if request.method == "POST", path == "/api/middleware/lmstudio/api-key" {
            logRequest(request)
            return await proxyMiddlewareLMStudioAPIKey(body: request.body)
        }
        if request.method == "POST", path == "/api/middleware/lmstudio/status" {
            logRequest(request)
            return await proxyMiddlewareLMStudioStatus(body: request.body)
        }
        if request.method == "POST", path == "/api/middleware/openai/login" {
            logRequest(request)
            return await proxyMiddlewareOpenAILogin(body: request.body)
        }
        if request.method == "POST", path == "/api/middleware/openai/status" {
            logRequest(request)
            return await proxyMiddlewareOpenAIStatus(body: request.body)
        }

        return notFound(json: path.hasPrefix("/api/"))
    }

    private func logRequest(_ request: PocketWikiHTTPRequest) {
        log(PocketWikiServerLogEntry(level: .info, message: "\(request.method) \(request.urlPath)"))
    }

    private func solutionID(from path: String) -> String? {
        let prefix = "/api/v1/solutions/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func configPayload() async -> [String: JSONValue] {
        let source = await sourceProvider()
        return [
            "referenceName": .string(source.rootName),
            "referenceSource": .string(source.source),
            "referenceConfigured": .bool(source.configured),
            "referenceReadonly": .bool(source.readonly),
            "referenceAvailable": .bool(source.available),
            "referenceStatus": .string(source.status),
            "mcpEvidence": PocketWikiMCPEvidenceStatus.make(
                rootPath: source.rootPath ?? configuration.resolvedReferenceURL.path,
                rootAvailable: source.available,
                rootStatus: source.status
            ).jsonValue,
            "lmStudioModel": .string(configuration.lmStudioModel),
            "lmStudioBaseUrl": .string(configuration.lmStudioBaseURL),
            "pocketKernelBaseUrl": .string(configuration.pocketKernelBaseURL),
            "middlewareAuthBaseUrl": .string(configuration.middlewareAuthBaseURL),
            "middlewareAuthProjectId": .string(configuration.middlewareAuthProjectID),
            "middlewareAuthProfileId": .string(configuration.middlewareAuthProfileID),
            "kernelProxy": .bool(true),
            "middlewareAuthProxy": .bool(true)
        ]
    }

    static func filesPayload(_ source: PocketWikiServedSource) -> PocketWikiFilesPayload {
        PocketWikiFilesPayload(source: source)
    }

    private func proxyPocketKernel(body: Data) async -> PocketWikiHTTPResponse {
        let url: URL
        do {
            url = try PocketKernelEndpointPolicy.kernelURL(configuration.pocketKernelBaseURL)
        } catch {
            return jsonError("invalid_pocketkernel_endpoint", status: 502)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/json; charset=utf-8"
            return PocketWikiHTTPResponse(
                status: status,
                headers: ["Cache-Control": "no-store, no-transform"],
                body: data,
                contentType: contentType
            )
        } catch {
            log(PocketWikiServerLogEntry(level: .error, message: "Proxy PocketKernel falhou: \(error.localizedDescription)"))
            return jsonError("pocketkernel_proxy_failed", status: 502)
        }
    }

    private func proxyMiddlewareLMStudioAPIKey(body: Data) async -> PocketWikiHTTPResponse {
        let input = requestObject(body)
        let baseURL = stringValue(input["middlewareBaseUrl"]).pocketIfEmpty(configuration.middlewareAuthBaseURL)
        let projectID = stringValue(input["projectId"]).pocketIfEmpty(configuration.middlewareAuthProjectID).pocketIfEmpty("acme")
        let profileID = stringValue(input["profileId"]).pocketIfEmpty(configuration.middlewareAuthProfileID).pocketIfEmpty("default")
        let lmStudioBaseURL = stringValue(input["baseUrl"]).pocketIfEmpty(configuration.lmStudioBaseURL).pocketIfEmpty("http://127.0.0.1:1234")
        let apiKey = stringValue(input["apiKey"])
        guard !configuration.middlewareAuthClientToken.pocketTrimmed.isEmpty else {
            return jsonError("middlewareauth_token_missing", status: 401)
        }
        guard !apiKey.pocketTrimmed.isEmpty else {
            return jsonError("lmstudio_api_key_missing", status: 400)
        }

        do {
            let url = try MiddlewareAuthEndpointPolicy.endpointURL(
                baseURL: baseURL,
                path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/lmstudio/api-key"
            )
            let upstreamBody = try JSONSerialization.data(withJSONObject: [
                "profileId": profileID,
                "baseUrl": lmStudioBaseURL,
                "apiKey": apiKey
            ])
            return await proxyMiddlewareAuth(url: url, method: "POST", body: upstreamBody)
        } catch {
            return jsonError("invalid_middlewareauth_endpoint", status: 502)
        }
    }

    private func proxyMiddlewareLMStudioStatus(body: Data) async -> PocketWikiHTTPResponse {
        let input = requestObject(body)
        let baseURL = stringValue(input["middlewareBaseUrl"]).pocketIfEmpty(configuration.middlewareAuthBaseURL)
        let projectID = stringValue(input["projectId"]).pocketIfEmpty(configuration.middlewareAuthProjectID).pocketIfEmpty("acme")
        let profileID = stringValue(input["profileId"]).pocketIfEmpty(configuration.middlewareAuthProfileID).pocketIfEmpty("default")
        guard !configuration.middlewareAuthClientToken.pocketTrimmed.isEmpty else {
            return jsonError("middlewareauth_token_missing", status: 401)
        }

        do {
            let url = try MiddlewareAuthEndpointPolicy.endpointURL(
                baseURL: baseURL,
                path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/lmstudio/status",
                queryItems: [URLQueryItem(name: "profileId", value: profileID)]
            )
            return await proxyMiddlewareAuth(url: url, method: "GET", body: nil)
        } catch {
            return jsonError("invalid_middlewareauth_endpoint", status: 502)
        }
    }

    private func proxyMiddlewareOpenAILogin(body: Data) async -> PocketWikiHTTPResponse {
        let input = requestObject(body)
        let baseURL = stringValue(input["middlewareBaseUrl"]).pocketIfEmpty(configuration.middlewareAuthBaseURL)
        let projectID = stringValue(input["projectId"]).pocketIfEmpty(configuration.middlewareAuthProjectID).pocketIfEmpty("acme")
        let profileID = stringValue(input["profileId"]).pocketIfEmpty(configuration.middlewareAuthProfileID).pocketIfEmpty("default")
        let mode = stringValue(input["mode"]).pocketIfEmpty("device_code")
        guard !configuration.middlewareAuthClientToken.pocketTrimmed.isEmpty else {
            return jsonError("middlewareauth_token_missing", status: 401)
        }

        do {
            let url = try MiddlewareAuthEndpointPolicy.endpointURL(
                baseURL: baseURL,
                path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/openai/login"
            )
            let upstreamBody = try JSONSerialization.data(withJSONObject: [
                "profileId": profileID,
                "mode": mode
            ])
            return await proxyMiddlewareAuth(url: url, method: "POST", body: upstreamBody)
        } catch {
            return jsonError("invalid_middlewareauth_endpoint", status: 502)
        }
    }

    private func proxyMiddlewareOpenAIStatus(body: Data) async -> PocketWikiHTTPResponse {
        let input = requestObject(body)
        let baseURL = stringValue(input["middlewareBaseUrl"]).pocketIfEmpty(configuration.middlewareAuthBaseURL)
        let projectID = stringValue(input["projectId"]).pocketIfEmpty(configuration.middlewareAuthProjectID).pocketIfEmpty("acme")
        let profileID = stringValue(input["profileId"]).pocketIfEmpty(configuration.middlewareAuthProfileID).pocketIfEmpty("default")
        guard !configuration.middlewareAuthClientToken.pocketTrimmed.isEmpty else {
            return jsonError("middlewareauth_token_missing", status: 401)
        }

        do {
            let url = try MiddlewareAuthEndpointPolicy.endpointURL(
                baseURL: baseURL,
                path: "/v1/projects/\(MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme"))/auth/openai/status",
                queryItems: [URLQueryItem(name: "profileId", value: profileID)]
            )
            return await proxyMiddlewareAuth(url: url, method: "GET", body: nil)
        } catch {
            return jsonError("invalid_middlewareauth_endpoint", status: 502)
        }
    }

    private func proxyMiddlewareAuth(url: URL, method: String, body: Data?) async -> PocketWikiHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.middlewareAuthClientToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/json; charset=utf-8"
            return PocketWikiHTTPResponse(
                status: status,
                headers: ["Cache-Control": "no-store, no-transform"],
                body: data,
                contentType: contentType
            )
        } catch {
            log(PocketWikiServerLogEntry(level: .error, message: "Proxy MiddlewareAuth falhou: \(error.localizedDescription)"))
            return jsonError("middlewareauth_proxy_failed", status: 502)
        }
    }

    private func requestObject(_ body: Data) -> [String: Any] {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func stringValue(_ value: Any?) -> String {
        switch value {
        case let text as String:
            return text.pocketTrimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    private func fileResponse(_ relativePath: String, contentType: String, headers: [String: String] = [:], optional: Bool = false, headOnly: Bool) -> PocketWikiHTTPResponse {
        guard let url = webRoot?.appendingPathComponent(relativePath).standardizedFileURL,
              let root = webRoot?.standardizedFileURL,
              url.path.hasPrefix(root.path),
              let data = try? Data(contentsOf: url) else {
            return optional ? notFound(json: false) : jsonError("missing_web_asset", status: 500)
        }
        return PocketWikiHTTPResponse(status: 200, headers: headers, body: headOnly ? Data() : data, contentType: contentType)
    }

    private func assetResponse(_ path: String, headOnly: Bool) -> PocketWikiHTTPResponse {
        let relative = String(path.dropFirst())
        guard let decoded = relative.removingPercentEncoding else { return notFound() }
        return fileResponse(decoded, contentType: PocketWikiContentTypes.contentType(for: decoded), headOnly: headOnly)
    }

    private func jsonResponse<T: Encodable>(_ value: T, status: Int = 200) -> PocketWikiHTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return PocketWikiHTTPResponse(
            status: status,
            headers: ["Cache-Control": "no-store"],
            body: data,
            contentType: "application/json; charset=utf-8"
        )
    }

    private func jsonError(_ error: String, status: Int) -> PocketWikiHTTPResponse {
        jsonResponse(["error": error], status: status)
    }

    private func notFound(json: Bool = false) -> PocketWikiHTTPResponse {
        if json {
            return jsonError("not_found", status: 404)
        }
        return PocketWikiHTTPResponse(status: 404, body: Data("not_found".utf8), contentType: "text/plain; charset=utf-8")
    }

}

private final class ListenerStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PocketWikiRouteSnapshot, Error>?
    private var result: Result<PocketWikiRouteSnapshot, Error>?

    func value() async throws -> PocketWikiRouteSnapshot {
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

    func succeed(_ routes: PocketWikiRouteSnapshot) {
        complete(.success(routes))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<PocketWikiRouteSnapshot, Error>) {
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

private final class PocketWikiHTTPConnectionHandler: @unchecked Sendable {
    let id = UUID()

    private let connection: NWConnection
    private let route: @Sendable (PocketWikiHTTPRequest) async -> PocketWikiHTTPResponse
    private let onFinish: @Sendable (UUID) -> Void
    private let maxBodyBytes: Int
    private var buffer = Data()

    init(
        connection: NWConnection,
        maxBodyBytes: Int,
        route: @escaping @Sendable (PocketWikiHTTPRequest) async -> PocketWikiHTTPResponse,
        onFinish: @escaping @Sendable (UUID) -> Void
    ) {
        self.connection = connection
        self.maxBodyBytes = maxBodyBytes
        self.route = route
        self.onFinish = onFinish
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            if error != nil {
                self.finish()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            do {
                if let request = try PocketWikiHTTPRequest.parse(self.buffer, maxBodyBytes: self.maxBodyBytes) {
                    Task {
                        let response = await self.route(request)
                        self.send(response)
                    }
                } else if self.buffer.count > self.maxBodyBytes + 64 * 1024 {
                    self.send(PocketWikiHTTPResponse(
                        status: 413,
                        body: Data(#"{"error":"payload_too_large","message":"O payload excede o limite configurado."}"#.utf8),
                        contentType: "application/json; charset=utf-8"
                    ))
                } else {
                    self.receive()
                }
            } catch PocketWikiHTTPServerError.requestTooLarge {
                self.send(PocketWikiHTTPResponse(
                    status: 413,
                    body: Data(#"{"error":"payload_too_large","message":"O payload excede o limite configurado."}"#.utf8),
                    contentType: "application/json; charset=utf-8"
                ))
            } catch {
                self.send(PocketWikiHTTPResponse(status: 400, body: Data("bad_request".utf8), contentType: "text/plain; charset=utf-8"))
            }
        }
    }

    private func send(_ response: PocketWikiHTTPResponse) {
        let data = response.encoded()
        connection.send(content: data, completion: .contentProcessed { _ in
            self.finish()
        })
    }

    private func finish() {
        connection.cancel()
        onFinish(id)
    }

    func cancel() {
        finish()
    }
}

struct PocketWikiHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    var isHead: Bool { method == "HEAD" }

    var urlPath: String {
        let raw = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return raw.removingPercentEncoding ?? raw
    }

    static func parse(_ data: Data, maxBodyBytes: Int = PocketWikiSolutionIngestion.minimumRequestBytes) throws -> PocketWikiHTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw PocketWikiHTTPServerError.malformedRequest
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw PocketWikiHTTPServerError.malformedRequest
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw PocketWikiHTTPServerError.malformedRequest
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).pocketTrimmed
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0 else { throw PocketWikiHTTPServerError.malformedRequest }
        guard contentLength <= maxBodyBytes else { throw PocketWikiHTTPServerError.requestTooLarge }
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = contentLength > 0 ? data[bodyStart..<(bodyStart + contentLength)] : Data()
        return PocketWikiHTTPRequest(method: parts[0], target: parts[1], headers: headers, body: Data(body))
    }
}

struct PocketWikiHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let contentType: String

    init(status: Int, headers: [String: String] = [:], body: Data, contentType: String) {
        self.status = status
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }

    func encoded() -> Data {
        var lines = [
            "HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer"
        ]
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 412: "Precondition Failed"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "HTTP"
        }
    }
}

enum PocketWikiWebRuntimeResolver {
    static func webRoot(fileManager: FileManager = .default) throws -> URL {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true),
            Bundle.main.object(forInfoDictionaryKey: "PocketWikiRootPath")
                .flatMap { $0 as? String }
                .map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
        ].compactMap(\.self)

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("wiki-cockpit.html").path) {
                return candidate
            }
        }
        throw PocketWikiHTTPServerError.missingWebRoot
    }
}

private extension String {
    var trimmedSlash: String {
        replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }
}
