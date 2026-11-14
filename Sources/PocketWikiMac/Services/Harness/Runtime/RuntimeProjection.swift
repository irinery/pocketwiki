import Foundation
import CryptoKit

/// Monta uma visão isolada; o chamador publica `finish` atomicamente no cache por ambiente/thread.
final class RuntimeProjection {
    enum Failure: Error { case invalidPage, invalidEvent, overflow, stale, incomplete }
    struct View {
        let snapshotID: String
        let revision: Int
        let asOfSeq: Int
        let lastSeq: Int
        let appliedEventCount: Int
        let receipts: [String: [String: Any]]
        let effects: [String: [String: Any]]
    }
    private let schema: [String: Any]
    private let environmentID: String
    private let threadID: String
    private let pageSize: Int
    private let confirmedRevision: Int
    private let confirmedSeq: Int
    private var snapshotID: String?
    private var revision = 0
    private var boundary = 0
    private var nextCursor: String?
    private var started = false
    private var complete = false
    private var receipts: [String: [String: Any]] = [:]
    private var effects: [String: [String: Any]] = [:]
    private var events: [(Int, String, [String: Any])] = []
    private var eventBytes = 0
    // Reiniciar por snapshot quando a janela encher preserva detecção exata de conflitos.
    static let maxTrackedEvents = 4096
    private var invalidated = false
    private var seenEvents: [String: (Int, SHA256.Digest, SHA256.Digest?)] = [:]
    private var lastAppliedSeq = 0
    private var appliedEventCount = 0
    private var seenSequences: [Int: String] = [:]
    private var cursors = Set<String>()

    private static func canonicalUUID(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }
    private static func optionalUUID(_ value: Any?) -> Bool {
        value == nil || value is NSNull || canonicalUUID(value)
    }
    init(schema: [String: Any], environmentID: UUID, threadID: UUID, pageSize: Int, confirmedRevision: Int, confirmedSeq: Int = 0) throws {
        guard (1...100).contains(pageSize), confirmedRevision >= 0, confirmedSeq >= 0 else { throw Failure.invalidPage }
        self.schema = schema; self.environmentID = environmentID.uuidString.lowercased(); self.threadID = threadID.uuidString.lowercased()
        self.pageSize = pageSize; self.confirmedRevision = confirmedRevision; self.confirmedSeq = confirmedSeq
    }
    func appendPage(_ data: Data, requestedCursor: String?) throws {
        guard !complete, data.count <= 4_194_304, (!started && requestedCursor == nil) || (started && requestedCursor == nextCursor && requestedCursor != nil),
              let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              HarnessV1.validateCorpusValue(page, schemaName: "snapshotEnvelope", document: schema),
              page["module"] as? String == "runtime", let body = page["data"] as? [String: Any],
              let id = body["snapshot_id"] as? String, Self.canonicalUUID(id), let rev = body["revision"] as? Int, rev >= 0, rev <= 9_007_199_254_740_991,
              let seq = body["as_of_seq"] as? Int, seq >= 0, seq <= 9_007_199_254_740_991,
              let rs = body["receipts"] as? [[String: Any]], let es = body["effects"] as? [[String: Any]], rs.count + es.count <= pageSize else { throw Failure.invalidPage }
        guard rev >= confirmedRevision else { throw Failure.stale }
        if started && (id != snapshotID || rev != revision || seq != boundary) { throw Failure.invalidPage }
        let cursor = body["next_cursor"] as? String
        if let cursor, (cursor.utf8.count > 512 || !cursors.insert(cursor).inserted) { throw Failure.invalidPage }
        var newReceipts = receipts, newEffects = effects
        for item in rs {
            guard let key = item["command_id"] as? String, Self.canonicalUUID(key), Self.canonicalUUID(item["receipt_id"]),
                  Self.optionalUUID(item["effect_id"]), Self.optionalUUID(item["result_ref"]), newReceipts[key] == nil,
                  let itemRevision = item["revision"] as? Int, itemRevision >= 0, itemRevision <= rev else { throw Failure.invalidPage }
            newReceipts[key] = item
        }
        for item in es {
            guard let key = item["effect_id"] as? String, Self.canonicalUUID(key), Self.canonicalUUID(item["command_id"]),
                  Self.optionalUUID(item["result_ref"]), newEffects[key] == nil else { throw Failure.invalidPage }
            newEffects[key] = item
        }
        snapshotID = id; revision = rev; boundary = seq; receipts = newReceipts; effects = newEffects
        started = true; nextCursor = cursor; complete = cursor == nil
    }
    /// Eventos são validados antes de entrar no buffer; referência deve ser resolvida pelo transporte antes desta chamada.
    func bufferEvent(_ data: Data, resolvedPayload: Data? = nil) throws {
        guard !invalidated else { throw Failure.overflow }
        guard started, data.count + (resolvedPayload?.count ?? 0) <= 4_194_304 else {
            invalidated = true; throw Failure.overflow
        }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              HarnessV1.validateCorpusValue(event, schemaName: "streamEnvelope", document: schema),
              event["environment_id"] as? String == environmentID, event["thread_id"] as? String == threadID,
              event["module"] as? String == "runtime",
              let id = event["event_id"] as? String, Self.canonicalUUID(id), let seq = event["seq"] as? Int else { throw Failure.invalidEvent }
        let payload: [String: Any]
        if event["delivery"] as? String == "inline", resolvedPayload == nil, let inline = event["payload"] as? [String: Any] { payload = inline }
        else if event["delivery"] as? String == "reference", let resolvedPayload,
                let resolved = try? JSONSerialization.jsonObject(with: resolvedPayload) as? [String: Any],
                HarnessV1.validateCorpusValue(resolved, schemaName: "runtimeModuleEvent", document: schema) { payload = resolved }
        else { throw Failure.invalidEvent }
        if seq <= boundary { return }
        // JSON equivalente deve produzir a mesma identidade, independentemente da ordem ou espaços.
        let canonicalEvent = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .fragmentsAllowed])
        let canonicalPayload = try resolvedPayload.map { _ in
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed])
        }
        let digest = SHA256.hash(data: canonicalEvent), payloadDigest = canonicalPayload.map { SHA256.hash(data: $0) }
        if let previous = seenEvents[id] { if previous.0 == seq && previous.1 == digest && previous.2 == payloadDigest { return }; throw Failure.invalidEvent }
        if let previous = seenSequences[seq] { if previous == id { return }; throw Failure.invalidEvent }
        guard seq > (events.last?.0 ?? max(boundary, lastAppliedSeq)) else { throw Failure.invalidEvent }
        guard seenEvents.count < Self.maxTrackedEvents,
              eventBytes + data.count + (resolvedPayload?.count ?? 0) <= 4_194_304 else {
            invalidated = true; throw Failure.overflow
        }
        events.append((seq, id, payload)); seenEvents[id] = (seq, digest, payloadDigest); seenSequences[seq] = id; eventBytes += data.count + (resolvedPayload?.count ?? 0)
    }
    func finish() throws -> View {
        guard !invalidated else { throw Failure.overflow }
        guard complete, let id = snapshotID else { throw Failure.incomplete }
        guard (events.last?.0 ?? max(boundary, lastAppliedSeq)) >= confirmedSeq else { throw Failure.stale }
        var rs = receipts, es = effects
        var latestRevision = revision
        for (_, _, payload) in events {
            guard let type = payload["entity_type"] as? String, let entityKey = payload["entity_key"] as? String,
                  let change = payload["change"] as? String,
                  let keyData = entityKey.data(using: .utf8), let key = try? JSONSerialization.jsonObject(with: keyData, options: .fragmentsAllowed) as? String,
                  entityKey == "\"\(key)\"", Self.canonicalUUID(key) else { throw Failure.invalidEvent }
            if type == "RuntimeEvent" {
                if change == "upsert" {
                    guard let value = payload["value"] as? [String: Any], value["event_id"] as? String == key,
                          value["thread_id"] as? String == threadID else { throw Failure.invalidEvent }
                }
                continue
            }
            guard type == "RuntimeReceipt" || type == "EffectRecord" else { throw Failure.invalidEvent }
            let value = payload["value"] as? [String: Any]
            if change == "upsert" {
                guard let value, value[type == "RuntimeReceipt" ? "command_id" : "effect_id"] as? String == key else { throw Failure.invalidEvent }
                if type == "RuntimeReceipt" {
                    guard let newRevision = value["revision"] as? Int, newRevision >= 0, newRevision <= 9_007_199_254_740_991,
                          newRevision >= (rs[key]?["revision"] as? Int ?? 0) else { throw Failure.invalidEvent }
                    latestRevision = max(latestRevision, newRevision)
                    rs[key] = value
                } else { es[key] = value }
            } else if change == "delete" {
                if type == "RuntimeReceipt" { rs.removeValue(forKey: key) } else { es.removeValue(forKey: key) }
            } else { throw Failure.invalidEvent }
        }
        let newLastSeq = events.last?.0 ?? max(boundary, lastAppliedSeq)
        let newCount = appliedEventCount + events.count
        // Só publica e compacta depois de validar todos os eventos do lote.
        receipts = rs; effects = es; revision = latestRevision
        lastAppliedSeq = newLastSeq; appliedEventCount = newCount
        events.removeAll(keepingCapacity: false); eventBytes = 0
        return View(snapshotID: id, revision: latestRevision, asOfSeq: boundary, lastSeq: newLastSeq, appliedEventCount: newCount, receipts: rs, effects: es)
    }
}
