import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transporte isolado. O Kernel é responsável por autorização, ledger e recovery.
private final class RuntimeRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct RuntimeTransport {
    enum Failure: Error {
        case invalidURL, invalidArgument, invalidResponse
        case remote(status: Int, error: HarnessV1.Error)
    }

    private let baseURL: URL
    private let bearer: String
    private let session: URLSession
    private let redirectBlocker: RuntimeRedirectBlocker

    init(baseURL: URL, bearer: String) throws {
        let c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(c?.host ?? "")
        guard let c, (c.scheme == "https" || (c.scheme == "http" && loopback)), c.user == nil, c.password == nil,
              (c.path.isEmpty || c.path == "/"), c.query == nil, c.fragment == nil,
              !bearer.isEmpty, !bearer.contains("\n"), !bearer.contains("\r") else { throw Failure.invalidURL }
        let blocker = RuntimeRedirectBlocker()
        self.baseURL = baseURL; self.bearer = bearer; self.redirectBlocker = blocker
        self.session = URLSession(configuration: .ephemeral, delegate: blocker, delegateQueue: nil)
    }

    func capabilities<T: Decodable>() async throws -> T { try await get("/v1/harness/capabilities") }
    func receipt<T: Decodable>(commandID: UUID) async throws -> T {
        try await get("/v1/harness/receipts/\(commandID.uuidString.lowercased())")
    }
    func snapshot<T: Decodable>(threadID: UUID, pageSize: Int = 100, cursor: String? = nil) async throws -> T {
        guard (1...100).contains(pageSize), cursor.map({ $0.utf8.count <= 512 }) ?? true else { throw Failure.invalidArgument }
        var query = [URLQueryItem(name: "module", value: "runtime"), URLQueryItem(name: "page_size", value: String(pageSize))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request("/v1/harness/threads/\(threadID.uuidString.lowercased())/snapshot", query: query)
    }
    struct DispatchInput: Codable, Equatable {
        let commandID: UUID
        let threadID: UUID
        let expectedRevision: Int
        let operation: String
        let text: String
        let runID: UUID?
        enum CodingKeys: String, CodingKey {
            case operation, text
            case commandID = "command_id", threadID = "thread_id"
            case expectedRevision = "expected_revision", runID = "run_id"
        }
    }
    func dispatch<Result: Decodable>(_ command: HarnessV1.Command<DispatchInput>) async throws -> Result {
        let input = command.input
        guard command.protocolMajor == 1, command.operation == "runtime.dispatch", command.expectedRevision >= 0,
              input.commandID == command.commandID, input.expectedRevision == command.expectedRevision,
              input.text.utf8.count <= 32768,
              (input.operation == "submit" && !input.text.isEmpty && input.runID == nil) ||
              (["cancel", "resume"].contains(input.operation) && input.runID != nil) else { throw Failure.invalidArgument }
        var inputObject: [String: Any] = ["command_id": input.commandID.uuidString.lowercased(), "thread_id": input.threadID.uuidString.lowercased(), "expected_revision": input.expectedRevision, "operation": input.operation, "text": input.text]
        if let runID = input.runID { inputObject["run_id"] = runID.uuidString.lowercased() }
        let body = try JSONSerialization.data(withJSONObject: ["protocol_major": 1, "command_id": command.commandID.uuidString.lowercased(), "environment_id": command.environmentID.uuidString.lowercased(), "expected_revision": command.expectedRevision, "operation": command.operation, "input": inputObject])
        guard body.count <= 1_048_576 else { throw Failure.invalidArgument }
        return try await request("/v1/harness/commands", method: "POST", body: body)
    }
    func query<Input: Encodable, Result: Decodable>(_ operation: String, input: Input) async throws -> Result {
        guard ["runtime.receipt", "runtime.events"].contains(operation) else { throw Failure.invalidArgument }
        return try await request("/v1/harness/query/\(operation)", method: "POST", body: JSONEncoder().encode(input))
    }
    private func get<T: Decodable>(_ path: String) async throws -> T { try await request(path) }
    private func request<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw Failure.invalidURL }
        components.path = path; if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw Failure.invalidURL }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method; req.httpBody = body
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if !(200...299).contains(http.statusCode) {
            guard let remote = try? JSONDecoder().decode(HarnessV1.Error.self, from: data) else { throw Failure.invalidResponse }
            throw Failure.remote(status: http.statusCode, error: remote)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
