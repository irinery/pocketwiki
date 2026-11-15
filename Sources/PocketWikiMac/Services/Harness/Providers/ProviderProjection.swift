import Foundation
import CryptoKit

/// Reidrata o snapshot inteiro antes de publicar; payloads referenciados são resolvidos pelo transporte autenticado.
final class ProviderProjection {
    enum Failure: Error { case invalidPage, invalidEvent, stale, overflow, incomplete }
    struct View {
        let snapshotID: String
        let revision: Int
        let asOfSeq: Int
        let lastSeq: Int
        let bindings: [String: [String: Any]]
        let capabilities: [String: [String: Any]]
    }
    private let schema: [String: Any]
    private let environment: String
    private let pageSize: Int
    private let confirmedRevision: Int
    private let confirmedSeq: Int
    private var snapshotID: String?
    private var revision = 0
    private var boundary = 0
    private var nextCursor: String?
    private var started = false
    private var complete = false
    private var invalid = false
    private var cursors = Set<String>()
    private var bindings: [String: [String: Any]] = [:]
    private var capabilities: [String: [String: Any]] = [:]
    private var events: [(Int, [String: Any])] = []
    private var seen: [String: (Int, SHA256.Digest)] = [:]
    private var sequences: [Int: String] = [:]
    private var eventBytes = 0

    init(schema: [String: Any], environmentID: UUID, pageSize: Int, confirmedRevision: Int, confirmedSeq: Int = 0) throws {
        guard (1...100).contains(pageSize), confirmedRevision >= 0, confirmedSeq >= 0 else { throw Failure.invalidPage }
        self.schema = schema; self.environment = environmentID.uuidString.lowercased(); self.pageSize = pageSize
        self.confirmedRevision = confirmedRevision; self.confirmedSeq = confirmedSeq
    }
    private static func uuid(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }
    private func validEntity(_ value: [String: Any], type: String) -> Bool {
        guard HarnessV1.validateCorpusValue(value, schemaName: type, document: schema) else { return false }
        if type == "ProviderBinding" { guard let revision = value["catalog_revision"] as? Int else { return false }; return revision >= 1 && revision <= 9_007_199_254_740_991 }
        guard let version = value["version"] as? Int, version >= 0, version <= 9_007_199_254_740_991 else { return false }
        if let context = value["context_bytes"] { guard let bytes = context as? Int, bytes >= 0, bytes <= 9_007_199_254_740_991 else { return false } }
        return true
    }
    func appendPage(_ data: Data, requestedCursor: String?) throws {
        guard !invalid else { throw Failure.invalidPage }
        do { try readPage(data, requestedCursor: requestedCursor) } catch { invalid = true; throw error }
    }
    private func readPage(_ data: Data, requestedCursor: String?) throws {
        guard !complete, data.count <= 4_194_304, (!started && requestedCursor == nil) || (started && requestedCursor == nextCursor && requestedCursor != nil),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              HarnessV1.validateCorpusValue(body, schemaName: "providersFeatureSnapshot", document: schema),
              let id = body["snapshot_id"] as? String, Self.uuid(id), let rev = body["revision"] as? Int,
              let seq = body["as_of_seq"] as? Int, rev >= confirmedRevision, seq >= confirmedSeq,
              rev <= 9_007_199_254_740_991, seq <= 9_007_199_254_740_991,
              let bs = body["bindings"] as? [[String: Any]], let cs = body["capabilities"] as? [[String: Any]], bs.count + cs.count <= pageSize else { throw Failure.invalidPage }
        if started && (id != snapshotID || rev != revision || seq != boundary) { throw Failure.invalidPage }
        let cursor = body["next_cursor"] as? String
        if let cursor, (cursor.isEmpty || cursor.utf8.count > 512 || !cursors.insert(cursor).inserted) { throw Failure.invalidPage }
        var nextBindings = bindings, nextCapabilities = capabilities
        for value in bs {
            guard validEntity(value, type: "ProviderBinding"), let key = value["binding_id"] as? String, Self.uuid(key), Self.uuid(value["capability_id"]), nextBindings[key] == nil else { throw Failure.invalidPage }
            nextBindings[key] = value
        }
        for value in cs {
            guard validEntity(value, type: "ProviderCapabilities"), let key = value["capability_id"] as? String, Self.uuid(key), nextCapabilities[key] == nil else { throw Failure.invalidPage }
            nextCapabilities[key] = value
        }
        bindings = nextBindings; capabilities = nextCapabilities; snapshotID = id; revision = rev; boundary = seq
        started = true; nextCursor = cursor; complete = cursor == nil
    }
    func bufferEvent(_ data: Data, resolvedPayload: Data? = nil) throws {
        guard !invalid else { throw Failure.invalidEvent }
        do { try readEvent(data, resolvedPayload: resolvedPayload) } catch { invalid = true; throw error }
    }
    private func readEvent(_ data: Data, resolvedPayload: Data?) throws {
        guard started, eventBytes + data.count + (resolvedPayload?.count ?? 0) <= 4_194_304 else { throw Failure.overflow }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              HarnessV1.validateCorpusValue(event, schemaName: "streamEnvelope", document: schema),
              event["environment_id"] as? String == environment, event["thread_id"] == nil, event["module"] as? String == "providers",
              let id = event["event_id"] as? String, Self.uuid(id), let seq = event["seq"] as? Int, seq >= 0 else { throw Failure.invalidEvent }
        let payload: [String: Any]
        if event["delivery"] as? String == "inline", resolvedPayload == nil, let value = event["payload"] as? [String: Any] { payload = value }
        else if event["delivery"] as? String == "reference", let resolvedPayload,
                let value = try? JSONSerialization.jsonObject(with: resolvedPayload) as? [String: Any] { payload = value }
        else { throw Failure.invalidEvent }
        guard HarnessV1.validateCorpusValue(payload, schemaName: "providersModuleEvent", document: schema) else { throw Failure.invalidEvent }
        if seq <= boundary { return }
        let canonical = try JSONSerialization.data(withJSONObject: ["event": event, "payload": payload], options: [.sortedKeys])
        let digest = SHA256.hash(data: canonical)
        if let previous = seen[id] { if previous.0 == seq && previous.1 == digest { return }; throw Failure.invalidEvent }
        if sequences[seq] != nil { throw Failure.invalidEvent }
        guard seq > (events.last?.0 ?? boundary) else { throw Failure.invalidEvent }
        guard seen.count < 4096 else { throw Failure.overflow }
        seen[id] = (seq, digest); sequences[seq] = id; events.append((seq, payload)); eventBytes += data.count + (resolvedPayload?.count ?? 0)
    }
    func finish() throws -> View {
        guard !invalid, complete, let snapshotID else { throw Failure.incomplete }
        for binding in bindings.values { guard let id = binding["capability_id"] as? String, capabilities[id] != nil else { throw Failure.invalidPage } }
        var bs = bindings, cs = capabilities
        for (_, payload) in events {
            guard let type = payload["entity_type"] as? String, let keyJSON = payload["entity_key"] as? String,
                  let raw = keyJSON.data(using: .utf8), let key = try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed) as? String,
                  Self.uuid(key), keyJSON == "\"\(key)\"", let change = payload["change"] as? String else { throw Failure.invalidEvent }
            if change == "delete" { if type == "ProviderBinding" { bs.removeValue(forKey: key) } else if type == "ProviderCapabilities" { cs.removeValue(forKey: key) } else { throw Failure.invalidEvent }; continue }
            guard change == "upsert", let value = payload["value"] as? [String: Any], validEntity(value,type:type) else { throw Failure.invalidEvent }
            if type == "ProviderBinding", value["binding_id"] as? String == key { bs[key] = value }
            else if type == "ProviderCapabilities", value["capability_id"] as? String == key { cs[key] = value }
            else { throw Failure.invalidEvent }
        }
        return View(snapshotID: snapshotID, revision: revision, asOfSeq: boundary, lastSeq: events.last?.0 ?? boundary, bindings: bs, capabilities: cs)
    }
}
