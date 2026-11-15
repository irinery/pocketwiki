import Foundation

@main struct ProviderProjectionRunner {
    static func main() throws {
        let schemaData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let schema = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        let environment = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let projection = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        let binding: [String: Any] = ["binding_id":"11111111-1111-4111-8111-111111111111", "provider_id":"openai", "account_ref":"a", "model_id":"m", "mode":"inference", "catalog_revision":1, "capability_id":"22222222-2222-4222-8222-222222222222"]
        let capability: [String: Any] = ["capability_id":"22222222-2222-4222-8222-222222222222", "version":1, "stream_text":false, "steer":false, "interrupt":false, "rollback":false, "native_fork":false, "tools":false, "questions":false, "plans":false, "resume":false]
        func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        let first: [String: Any] = ["snapshot_id":"33333333-3333-4333-8333-333333333333", "revision":1, "as_of_seq":2, "bindings":[binding], "capabilities":[], "next_cursor":"cursor"]
        let second: [String: Any] = ["snapshot_id":"33333333-3333-4333-8333-333333333333", "revision":1, "as_of_seq":2, "bindings":[], "capabilities":[capability]]
        try projection.appendPage(bytes(first), requestedCursor: nil)
        var changed = binding; changed["model_id"] = "next"
        let payload: [String: Any] = ["entity_type":"ProviderBinding", "entity_key":"\"11111111-1111-4111-8111-111111111111\"", "change":"upsert", "value":changed]
        let event: [String: Any] = ["protocol_major":1, "environment_id":environment.uuidString.lowercased(), "module":"providers", "delivery":"inline", "committed_at_ms":1, "event_id":"44444444-4444-4444-8444-444444444444", "seq":3, "payload":payload]
        try projection.bufferEvent(bytes(event)); try projection.bufferEvent(bytes(event))
        try projection.appendPage(bytes(second), requestedCursor: "cursor")
        let view = try projection.finish()
        guard view.bindings.count == 1, view.capabilities.count == 1, view.lastSeq == 3,
              view.bindings["11111111-1111-4111-8111-111111111111"]?["model_id"] as? String == "next" else { fatalError("projection mismatch") }
        let conflictProjection = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        try conflictProjection.appendPage(bytes(first), requestedCursor: nil)
        try conflictProjection.bufferEvent(bytes(event))
        var conflicting = event; conflicting["seq"] = 4
        do { try conflictProjection.bufferEvent(bytes(conflicting)); fatalError("conflicting replay accepted") } catch ProviderProjection.Failure.invalidEvent { }
        let stale = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 2)
        do { try stale.appendPage(bytes(first), requestedCursor: nil); fatalError("stale snapshot accepted") } catch ProviderProjection.Failure.invalidPage { }
        print("ProviderProjection: ok")
    }
}
