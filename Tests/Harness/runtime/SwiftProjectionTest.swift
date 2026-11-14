import Foundation

@main struct Main {
    static func main() throws {
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "src/harness/contracts/harness-v1.schema.json"))) as! [String: Any]
        let id = "11111111-1111-4111-8111-111111111111"
        let id2 = "22222222-2222-4222-8222-222222222222"
        let uid = UUID(uuidString: id)!
        func encoded(_ v: Any) throws -> Data { try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) }
        func page(_ cursor: String?, _ snapshot: String = id) throws -> Data {
            var body: [String: Any] = ["snapshot_id": snapshot, "revision": 1, "as_of_seq": 2, "receipts": [], "effects": []]
            if let cursor { body["next_cursor"] = cursor }
            return try encoded(["module": "runtime", "data": body])
        }
        let projection = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 0)
        try projection.appendPage(page("cursor"), requestedCursor: nil)
        let payload: [String: Any] = ["entity_type": "EffectRecord", "entity_key": "\"\(id2)\"", "change": "upsert", "value": ["effect_id": id2, "command_id": id, "state": "succeeded"]]
        let event: [String: Any] = ["protocol_major": 1, "event_id": id2, "environment_id": id, "thread_id": id, "seq": 3, "committed_at_ms": 1, "module": "runtime", "delivery": "reference", "payload_ref": id]
        let eventData = try encoded(event), payloadData = try encoded(payload)
        try projection.bufferEvent(eventData, resolvedPayload: payloadData)
        try projection.bufferEvent(eventData, resolvedPayload: payloadData)
        do { _ = try projection.finish(); fatalError("incomplete snapshot accepted") } catch RuntimeProjection.Failure.incomplete { }
        do { try projection.appendPage(page(nil, id2), requestedCursor: "cursor"); fatalError("different boundary accepted") } catch RuntimeProjection.Failure.invalidPage { }
        try projection.appendPage(page(nil), requestedCursor: "cursor")
        let view = try projection.finish()
        guard view.effects[id2] != nil, view.lastSeq == 3, view.asOfSeq == 2 else { fatalError("projection incorrect") }
        let wrong: [String: Any] = ["entity_type": "EffectRecord", "entity_key": "\"\(id)\"", "change": "upsert", "value": ["effect_id": id2, "command_id": id, "state": "pending"]]
        let p2 = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 0)
        try p2.appendPage(page(nil), requestedCursor: nil)
        try p2.bufferEvent(eventData, resolvedPayload: encoded(wrong))
        do { _ = try p2.finish(); fatalError("wrong entity key accepted") } catch RuntimeProjection.Failure.invalidEvent { }
        let stale = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 2)
        do { try stale.appendPage(page(nil), requestedCursor: nil); fatalError("stale snapshot accepted") } catch RuntimeProjection.Failure.stale { }
        let p3 = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 0)
        try p3.appendPage(page(nil), requestedCursor: nil)
        do { try p3.bufferEvent(eventData); fatalError("unresolved reference accepted") } catch RuntimeProjection.Failure.invalidEvent { }
        do { try p3.bufferEvent(Data(repeating: 65, count: 4_194_305)); fatalError("overflow accepted") } catch RuntimeProjection.Failure.overflow { }
        let p4 = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 0, confirmedSeq: 4)
        try p4.appendPage(page(nil), requestedCursor: nil)
        do { _ = try p4.finish(); fatalError("older sequence accepted") } catch RuntimeProjection.Failure.stale { }
        let p5 = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 0)
        try p5.appendPage(page("cursor"), requestedCursor: nil)
        do { try p5.appendPage(page("cursor"), requestedCursor: "cursor"); fatalError("repeated cursor accepted") } catch RuntimeProjection.Failure.invalidPage { }
        var wrongEnvironment = event; wrongEnvironment["environment_id"] = id2
        do { try p3.bufferEvent(encoded(wrongEnvironment), resolvedPayload: payloadData); fatalError("wrong environment accepted") } catch RuntimeProjection.Failure.invalidEvent { }
        let p7 = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 0)
        try p7.appendPage(page(nil), requestedCursor: nil)
        let updatedReceipt: [String: Any] = ["entity_type": "RuntimeReceipt", "entity_key": "\"\(id)\"", "change": "upsert", "value": ["command_id": id, "receipt_id": id, "payload_sha256": String(repeating: "a", count: 64), "revision": 2, "state": "succeeded"]]
        try p7.bufferEvent(eventData, resolvedPayload: encoded(updatedReceipt))
        guard try p7.finish().revision == 2 else { fatalError("event revision not reflected") }
        let budget = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 0)
        try budget.appendPage(page(nil), requestedCursor: nil)
        var almostFull = eventData
        almostFull.append(Data(repeating: 32, count: 4_194_304 - eventData.count - payloadData.count - 100))
        try budget.bufferEvent(almostFull, resolvedPayload: payloadData)
        try budget.bufferEvent(almostFull, resolvedPayload: payloadData)
        guard try budget.finish().appliedEventCount == 1 else { fatalError("duplicate counted twice") }
        var nextEvent = event; nextEvent["event_id"] = id; nextEvent["seq"] = 4
        do { try budget.bufferEvent(encoded(nextEvent), resolvedPayload: payloadData); fatalError("overflow accepted") } catch RuntimeProjection.Failure.overflow { }
        let p6 = try RuntimeProjection(schema: schema, environmentID: uid, threadID: uid, pageSize: 1, confirmedRevision: 0)
        try p6.appendPage(page(nil), requestedCursor: nil)
        try p6.bufferEvent(eventData, resolvedPayload: payloadData)
        do { try p6.bufferEvent(eventData, resolvedPayload: encoded(wrong)); fatalError("changed payload accepted as duplicate") } catch RuntimeProjection.Failure.invalidEvent { }
    }
}
