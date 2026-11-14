import Foundation

@main struct Main {
    static func main() throws {
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "src/harness/contracts/harness-v1.schema.json"))) as! [String: Any]
        let id = "11111111-1111-4111-8111-111111111111", id2 = "22222222-2222-4222-8222-222222222222"
        let uuid = UUID(uuidString: id)!
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        let projection = try RuntimeProjection(schema: schema, environmentID: uuid, threadID: uuid, pageSize: 100, confirmedRevision: 0)
        try projection.appendPage(json(["module": "runtime", "data": ["snapshot_id": id, "revision": 1, "as_of_seq": 10, "receipts": [], "effects": []]]), requestedCursor: nil)
        for seq in [9, 10, 11] {
            let payload: [String: Any] = ["entity_type": "EffectRecord", "entity_key": "\"\(id2)\"", "change": "upsert", "value": ["effect_id": id2, "command_id": id, "state": "succeeded"]]
            let frame: [String: Any] = ["protocol_major": 1, "event_id": id2, "environment_id": id, "thread_id": id, "seq": seq, "committed_at_ms": 1, "module": "runtime", "delivery": "inline", "payload": payload]
            try projection.bufferEvent(json(frame))
        }
        let view = try projection.finish()
        guard view.asOfSeq == 10, view.lastSeq == 11, view.effects.count == 1, view.appliedEventCount == 1 else { fatalError("replay literal incorreto") }
        print("Swift literal B=10: 9/10 ignorados, 11 aplicado")
    }
}
