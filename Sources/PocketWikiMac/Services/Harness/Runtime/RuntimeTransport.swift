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
    private let commandSession: URLSession
    private let streamSession: URLSession
    private let redirectBlocker: RuntimeRedirectBlocker

    init(baseURL: URL, bearer: String, requestTimeout: TimeInterval = 30, commandTimeout: TimeInterval = 5) throws {
        let c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(c?.host ?? "")
        guard let c, (c.scheme == "https" || (c.scheme == "http" && loopback)), c.user == nil, c.password == nil,
              (c.path.isEmpty || c.path == "/"), c.query == nil, c.fragment == nil,
              !bearer.isEmpty, !bearer.contains("\n"), !bearer.contains("\r"), requestTimeout > 0, requestTimeout <= 30,
              commandTimeout > 0, commandTimeout <= 5 else { throw Failure.invalidURL }
        let blocker = RuntimeRedirectBlocker()
        self.baseURL = baseURL; self.bearer = bearer; self.redirectBlocker = blocker
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        self.session = URLSession(configuration: configuration, delegate: blocker, delegateQueue: nil)
        let commandConfiguration = configuration.copy() as! URLSessionConfiguration
        commandConfiguration.timeoutIntervalForRequest = commandTimeout
        commandConfiguration.timeoutIntervalForResource = commandTimeout
        self.commandSession = URLSession(configuration: commandConfiguration, delegate: blocker, delegateQueue: nil)
        let streamConfiguration = configuration.copy() as! URLSessionConfiguration
        streamConfiguration.timeoutIntervalForResource = 604_800
        self.streamSession = URLSession(configuration: streamConfiguration, delegate: blocker, delegateQueue: nil)
    }

    struct Capabilities: Decodable {
        let protocolMajor: Int
        let protocolMinor: Int
        let schemaSHA256: String
        let environmentID: UUID
        let operations: [String]
        enum CodingKeys: String, CodingKey {
            case operations
            case protocolMajor = "protocol_major", protocolMinor = "protocol_minor"
            case schemaSHA256 = "schema_sha256", environmentID = "environment_id"
        }
    }
    func capabilities(environmentID: UUID, schemaSHA256: String) async throws -> Capabilities {
        let value: Capabilities = try await request("/v1/harness/capabilities", validateCapabilities: true)
        guard value.environmentID == environmentID, value.schemaSHA256 == schemaSHA256 else { throw Failure.invalidResponse }
        return value
    }
    struct HTTPReceipt: Decodable {
        let commandID: UUID
        let receiptID: UUID
        let environmentID: UUID
        let revision: Int
        let state: String
        let duplicate: Bool
        let resultRef: UUID?
        enum CodingKeys: String, CodingKey {
            case revision, state, duplicate
            case commandID = "command_id", receiptID = "receipt_id", environmentID = "environment_id", resultRef = "result_ref"
        }
    }
    func receipt(commandID: UUID, environmentID: UUID) async throws -> HTTPReceipt {
        let receipt: HTTPReceipt = try await request("/v1/harness/receipts/\(commandID.uuidString.lowercased())", validateReceipt: true)
        guard receipt.commandID == commandID, receipt.environmentID == environmentID else { throw Failure.invalidResponse }
        return receipt
    }
    func snapshot<T: Decodable>(threadID: UUID, pageSize: Int = 100, cursor: String? = nil, schema: [String: Any]) async throws -> T {
        guard (1...100).contains(pageSize), cursor.map({ $0.utf8.count <= 512 }) ?? true else { throw Failure.invalidArgument }
        var query = [URLQueryItem(name: "module", value: "runtime"), URLQueryItem(name: "page_size", value: String(pageSize))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await request("/v1/harness/threads/\(threadID.uuidString.lowercased())/snapshot", query: query, snapshotSchema: schema, pageSize: pageSize)
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
    func dispatch(_ command: HarnessV1.Command<DispatchInput>) async throws -> HTTPReceipt {
        let input = command.input
        guard command.protocolMajor == 1, command.operation == "runtime.dispatch", command.expectedRevision >= 0, command.expectedRevision <= 9_007_199_254_740_991,
              input.commandID == command.commandID, input.expectedRevision == command.expectedRevision,
              input.text.utf8.count <= 32768,
              (input.operation == "submit" && !input.text.isEmpty && input.runID == nil) ||
              (["cancel", "resume"].contains(input.operation) && input.runID != nil) else { throw Failure.invalidArgument }
        var inputObject: [String: Any] = ["command_id": input.commandID.uuidString.lowercased(), "thread_id": input.threadID.uuidString.lowercased(), "expected_revision": input.expectedRevision, "operation": input.operation, "text": input.text]
        if let runID = input.runID { inputObject["run_id"] = runID.uuidString.lowercased() }
        let body = try JSONSerialization.data(withJSONObject: ["protocol_major": 1, "command_id": command.commandID.uuidString.lowercased(), "environment_id": command.environmentID.uuidString.lowercased(), "expected_revision": command.expectedRevision, "operation": command.operation, "input": inputObject])
        guard body.count <= 1_048_576 else { throw Failure.invalidArgument }
        let receipt: HTTPReceipt = try await request("/v1/harness/commands", method: "POST", body: body, validateReceipt: true)
        guard receipt.commandID == command.commandID, receipt.environmentID == command.environmentID else { throw Failure.invalidResponse }
        return receipt
    }
    struct DispatchResult: Decodable {
        let receiptID: UUID
        let revision: Int
        let state: String
        enum CodingKeys: String, CodingKey { case revision, state; case receiptID = "receipt_id" }
    }
    func result(ref: UUID, schema: [String: Any]) async throws -> DispatchResult {
        try await request("/v1/harness/results/\(ref.uuidString.lowercased())", resultSchema: schema)
    }
    struct ReceiptResult: Decodable {
        let receiptID: UUID
        let revision: Int
        let state: String
        enum CodingKeys: String, CodingKey { case revision, state; case receiptID = "receipt_id" }
    }
    struct RuntimeEvent: Decodable {
        let eventID: UUID
        let threadID: UUID
        let seq: Int
        let kind: String
        let effectID: UUID?
        enum CodingKeys: String, CodingKey { case seq, kind; case eventID = "event_id", threadID = "thread_id", effectID = "effect_id" }
    }
    struct EventsResult: Decodable { let events: [RuntimeEvent]; let next_seq: Int }
    func queryReceipt(commandID: UUID) async throws -> ReceiptResult {
        let body = try JSONSerialization.data(withJSONObject: ["command_id": commandID.uuidString.lowercased()])
        return try await request("/v1/harness/query/runtime.receipt", method: "POST", body: body, queryOperation: "runtime.receipt")
    }
    func queryEvents(threadID: UUID, afterSeq: Int, limit: Int, schema: [String: Any]) async throws -> EventsResult {
        guard afterSeq >= 0, afterSeq <= 9_007_199_254_740_991, (1...100).contains(limit) else { throw Failure.invalidArgument }
        let body = try JSONSerialization.data(withJSONObject: ["thread_id": threadID.uuidString.lowercased(), "after_seq": afterSeq, "limit": limit])
        let result: EventsResult = try await request("/v1/harness/query/runtime.events", method: "POST", body: body, snapshotSchema: nil, queryOperation: "runtime.events", querySchema: schema)
        guard result.events.count <= limit, result.events.allSatisfy({ $0.threadID == threadID && $0.seq > afterSeq }),
              result.events.map(\.seq) == result.events.map(\.seq).sorted(),
              Set(result.events.map(\.seq)).count == result.events.count,
              result.next_seq >= (result.events.last?.seq ?? afterSeq) else { throw Failure.invalidResponse }
        return result
    }
    /// Busca referência autenticada sem alocar mais de 4 MiB e valida o payload de runtime E0.
    func payload(ref: UUID, schema: [String: Any]) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw Failure.invalidURL }
        components.path = "/v1/harness/payloads/\(ref.uuidString.lowercased())"
        guard let url = components.url else { throw Failure.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        var data = Data()
        let limit = (200...299).contains(http.statusCode) ? 4_194_304 : 4096
        for try await byte in bytes {
            guard data.count < limit else { throw Failure.invalidResponse }
            data.append(byte)
        }
        if !(200...299).contains(http.statusCode) {
            guard let remote = Self.decodeRemoteError(data) else { throw Failure.invalidResponse }
            throw Failure.remote(status: http.statusCode, error: remote)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              HarnessV1.validateCorpusValue(object, schemaName: "runtimeModuleEvent", document: schema) else { throw Failure.invalidResponse }
        return data
    }
    /// Entrega somente envelopes completos e válidos. Cancelar a sequência encerra a conexão.
    func stream<Payload: Codable & Equatable & Sendable>(environmentID: UUID, threadID: UUID, afterSeq: Int,
        payloadType: Payload.Type, schemaData: Data) throws -> AsyncThrowingStream<HarnessV1.StreamEnvelope<Payload>, Error> {
        guard afterSeq >= 0, afterSeq <= 9_007_199_254_740_991 else { throw Failure.invalidArgument }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw Failure.invalidURL }
        components.path = "/v1/harness/streams/thread/\(threadID.uuidString.lowercased())"
        components.queryItems = [URLQueryItem(name: "after_seq", value: String(afterSeq)), URLQueryItem(name: "modules", value: "runtime")]
        guard let url = components.url else { throw Failure.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(String(afterSeq), forHTTPHeaderField: "Last-Event-ID")
        let session = self.streamSession
        let streamRequest = request
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { continuation in
            let task = Task {
                do {
                    guard let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else { throw Failure.invalidResponse }
                    let (bytes, response) = try await session.bytes(for: streamRequest)
                    guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                    if !(200...299).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            guard data.count < 4096 else { throw Failure.invalidResponse }
                            data.append(byte)
                        }
                        guard let remote = Self.decodeRemoteError(data) else { throw Failure.invalidResponse }
                        throw Failure.remote(status: http.statusCode, error: remote)
                    }
                    guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else { throw Failure.invalidResponse }
                    var line = Data(), dataLines: [String] = []
                    var eventID: String?, frameSize = 0
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        frameSize += 1
                        guard frameSize <= 262_144 else { throw Failure.invalidResponse }
                        if byte != 10 { line.append(byte); continue }
                        if line.last == 13 { line.removeLast() }
                        guard let text = String(data: line, encoding: .utf8) else { throw Failure.invalidResponse }
                        line.removeAll(keepingCapacity: true)
                        if text.isEmpty {
                            if !dataLines.isEmpty {
                                guard let eventID, let seq = Int(eventID), eventID == String(seq), seq >= 0,
                                      let data = dataLines.joined(separator: "\n").data(using: .utf8),
                                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                      HarnessV1.validateCorpusValue(object, schemaName: "streamEnvelope", document: schema),
                                      Self.canonicalUUID(object["event_id"]), Self.canonicalUUID(object["environment_id"]),
                                      Self.canonicalUUID(object["thread_id"]),
                                      (object["payload_ref"] == nil || Self.canonicalUUID(object["payload_ref"])),
                                      seq <= 9_007_199_254_740_991,
                                      let envelope = try? JSONDecoder().decode(HarnessV1.StreamEnvelope<Payload>.self, from: data),
                                      envelope.environmentID == environmentID, envelope.threadID == threadID, envelope.module == .runtime, envelope.seq == seq else { throw Failure.invalidResponse }
                                try envelope.validate()
                                if let payload = object["payload"], try JSONSerialization.data(withJSONObject: payload).count > 262_144 { throw Failure.invalidResponse }
                                if case .dropped = continuation.yield(envelope) { throw Failure.invalidResponse }
                            }
                            dataLines.removeAll(keepingCapacity: true); eventID = nil; frameSize = 0
                        } else if !text.hasPrefix(":") {
                            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                            let field = String(parts[0]); var value = parts.count == 2 ? String(parts[1]) : ""
                            if value.first == " " { value.removeFirst() }
                            if field == "data" { dataLines.append(value) }
                            else if field == "id" { eventID = value }
                        }
                    }
                    // An interrupted or incomplete frame is never emitted.
                    if !line.isEmpty || !dataLines.isEmpty { throw Failure.invalidResponse }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func canonicalUUID(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }
    private static func decodeRemoteError(_ data: Data) -> HarnessV1.Error? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["code", "message", "correlation_id", "retryable"]),
              let error = try? JSONDecoder().decode(HarnessV1.Error.self, from: data),
              error.code.hasPrefix("ERR_"), error.code.utf8.count <= 128, error.message.utf8.count <= 1024,
              canonicalUUID(object["correlation_id"]) else { return nil }
        return error
    }
    private func get<T: Decodable>(_ path: String) async throws -> T { try await request(path) }
    private func request<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, snapshotSchema: [String: Any]? = nil, pageSize: Int = 100, validateReceipt: Bool = false, validateCapabilities: Bool = false, queryOperation: String? = nil, querySchema: [String: Any]? = nil, resultSchema: [String: Any]? = nil) async throws -> T {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw Failure.invalidURL }
        components.path = path; if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw Failure.invalidURL }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method; req.httpBody = body
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let activeSession = path == "/v1/harness/commands" ? commandSession : session
        let (bytes, response) = try await activeSession.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        var data = Data()
        let limit = (200...299).contains(http.statusCode) ? 4_194_304 : 4096
        for try await byte in bytes { guard data.count < limit else { throw Failure.invalidResponse }; data.append(byte) }
        if !(200...299).contains(http.statusCode) {
            guard let remote = Self.decodeRemoteError(data) else { throw Failure.invalidResponse }
            throw Failure.remote(status: http.statusCode, error: remote)
        }
        if let resultSchema {
            guard let raw = try? JSONSerialization.jsonObject(with: data),
                  HarnessV1.validateCorpusValue(raw, schemaName: "commandReceipt", document: resultSchema) else { throw Failure.invalidResponse }
        }
        if let queryOperation {
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
            if queryOperation == "runtime.receipt" {
                guard Set(raw.keys) == Set(["receipt_id", "revision", "state"]), Self.canonicalUUID(raw["receipt_id"]),
                      let result = try? JSONDecoder().decode(ReceiptResult.self, from: data), result.revision >= 0,
                      result.revision <= 9_007_199_254_740_991,
                      ["accepted", "pending", "succeeded", "failed", "uncertain"].contains(result.state) else { throw Failure.invalidResponse }
            } else {
                guard let querySchema, Set(raw.keys) == Set(["events", "next_seq"]),
                      let events = raw["events"] as? [Any], events.count <= 100,
                      events.allSatisfy({ HarnessV1.validateCorpusValue($0, schemaName: "RuntimeEvent", document: querySchema) }),
                      let result = try? JSONDecoder().decode(EventsResult.self, from: data), result.next_seq >= 0,
                      result.next_seq <= 9_007_199_254_740_991,
                      result.events.allSatisfy({ $0.seq >= 0 && $0.seq <= 9_007_199_254_740_991 }) else { throw Failure.invalidResponse }
            }
        }
        if validateCapabilities {
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(raw.keys) == Set(["protocol_major", "protocol_minor", "schema_sha256", "environment_id", "operations"]),
                  let value = try? JSONDecoder().decode(Capabilities.self, from: data),
                  value.protocolMajor == 1, value.protocolMinor == 0,
                  value.schemaSHA256.utf8.count == 64,
                  value.schemaSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  Self.canonicalUUID(raw["environment_id"]),
                  value.operations.count <= 100, Set(value.operations).count == value.operations.count,
                  value.operations.allSatisfy({ HarnessOperationRegistry.entries[$0] != nil }) else { throw Failure.invalidResponse }
        }
        if validateReceipt {
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(value.keys).isSubset(of: ["command_id", "receipt_id", "environment_id", "revision", "state", "duplicate", "result_ref"]),
                  let receipt = try? JSONDecoder().decode(HTTPReceipt.self, from: data),
                  receipt.revision >= 0, receipt.revision <= 9_007_199_254_740_991,
                  ["accepted", "pending", "succeeded", "failed", "uncertain"].contains(receipt.state) else { throw Failure.invalidResponse }
            for field in ["command_id", "receipt_id", "environment_id"] {
                guard Self.canonicalUUID(value[field]) else { throw Failure.invalidResponse }
            }
            if let raw = value["result_ref"], !(raw is NSNull) {
                guard Self.canonicalUUID(raw) else { throw Failure.invalidResponse }
            }
        }
        if let snapshotSchema {
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  HarnessV1.validateCorpusValue(value, schemaName: "snapshotEnvelope", document: snapshotSchema),
                  value["module"] as? String == "runtime", let page = value["data"] as? [String: Any],
                  let revision = page["revision"] as? Int, revision >= 0, revision <= 9_007_199_254_740_991,
                  let seq = page["as_of_seq"] as? Int, seq >= 0, seq <= 9_007_199_254_740_991,
                  let receipts = page["receipts"] as? [Any], let effects = page["effects"] as? [Any],
                  receipts.count + effects.count <= pageSize,
                  (page["next_cursor"] as? String).map({ $0.utf8.count <= 512 }) ?? true else { throw Failure.invalidResponse }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
