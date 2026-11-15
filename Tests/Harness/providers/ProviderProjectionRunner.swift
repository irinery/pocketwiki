import Foundation

@main struct ProviderProjectionRunner {
    static func main() throws {
        let schemaData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let schema = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        let environment = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let scope = ProviderProjection.Scope(principal: "alice", generation: "1")
        let projection = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        projection.setScope(scope)
        let binding: [String: Any] = ["binding_id":"11111111-1111-4111-8111-111111111111", "provider_id":"openai", "account_ref":"a", "model_id":"m", "mode":"inference", "catalog_revision":1, "capability_id":"22222222-2222-4222-8222-222222222222"]
        let capability: [String: Any] = ["capability_id":"22222222-2222-4222-8222-222222222222", "version":1, "stream_text":false, "steer":false, "interrupt":false, "rollback":false, "native_fork":false, "tools":false, "questions":false, "plans":false, "resume":false]
        func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        let first: [String: Any] = ["snapshot_id":"33333333-3333-4333-8333-333333333333", "revision":1, "as_of_seq":2, "bindings":[binding], "capabilities":[], "next_cursor":"cursor"]
        let second: [String: Any] = ["snapshot_id":"33333333-3333-4333-8333-333333333333", "revision":1, "as_of_seq":2, "bindings":[], "capabilities":[capability]]
        try projection.appendPage(bytes(first), requestedCursor: nil, scope: scope)
        var changed = binding; changed["model_id"] = "next"
        let payload: [String: Any] = ["entity_type":"ProviderBinding", "entity_key":"\"11111111-1111-4111-8111-111111111111\"", "change":"upsert", "value":changed]
        let event: [String: Any] = ["protocol_major":1, "environment_id":environment.uuidString.lowercased(), "module":"providers", "delivery":"inline", "committed_at_ms":1, "event_id":"44444444-4444-4444-8444-444444444444", "seq":3, "payload":payload]
        try projection.bufferEvent(bytes(event), scope: scope); try projection.bufferEvent(bytes(event), scope: scope)
        try projection.appendPage(bytes(second), requestedCursor: "cursor", scope: scope)
        let view = try projection.finish(scope: scope)
        guard view.bindings.count == 1, view.capabilities.count == 1, view.lastSeq == 3,
              view.bindings["11111111-1111-4111-8111-111111111111"]?["model_id"] as? String == "next" else { fatalError("projection mismatch") }
        let conflictProjection = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        conflictProjection.setScope(scope)
        try conflictProjection.appendPage(bytes(first), requestedCursor: nil, scope: scope)
        try conflictProjection.bufferEvent(bytes(event), scope: scope)
        var conflicting = event; conflicting["seq"] = 4
        do { try conflictProjection.bufferEvent(bytes(conflicting), scope: scope); fatalError("conflicting replay accepted") } catch ProviderProjection.Failure.invalidEvent { }
        let stale = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 2)
        stale.setScope(scope)
        do { try stale.appendPage(bytes(first), requestedCursor: nil, scope: scope); fatalError("stale snapshot accepted") } catch ProviderProjection.Failure.invalidPage { }
        let bob = ProviderProjection.Scope(principal: "bob", generation: "1")
        let bob2 = ProviderProjection.Scope(principal: "bob", generation: "2")
        let isolated = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        do { try isolated.appendPage(bytes(first), requestedCursor: nil); fatalError("unscoped accepted") } catch ProviderProjection.Failure.inactiveScope { }
        isolated.setScope(scope)
        try isolated.appendPage(bytes(first), requestedCursor: nil, scope: scope)
        try isolated.bufferEvent(bytes(event), scope: scope)
        isolated.setScope(bob)
        do { try isolated.appendPage(bytes(second), requestedCursor: "cursor", scope: scope); fatalError("stale page accepted") } catch ProviderProjection.Failure.inactiveScope { }
        do { _ = try isolated.finish(scope: bob); fatalError("old snapshot survived") } catch ProviderProjection.Failure.incomplete { }
        try isolated.appendPage(bytes(first), requestedCursor: nil, scope: bob)
        try isolated.appendPage(bytes(second), requestedCursor: "cursor", scope: bob)
        guard try isolated.finish(scope: bob).lastSeq == 2 else { fatalError("old event survived") }
        isolated.setScope(bob2)
        do { _ = try isolated.finish(scope: bob); fatalError("old generation accepted") } catch ProviderProjection.Failure.inactiveScope { }
        do { _ = try isolated.finish(scope: bob2); fatalError("old generation state survived") } catch ProviderProjection.Failure.incomplete { }
        isolated.setScope(nil)
        do { _ = try isolated.finish(scope: bob2); fatalError("inactive scope accepted") } catch ProviderProjection.Failure.inactiveScope { }
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        for slot in corpus["slots"] as! [[String: Any]] {
            let check = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 100, confirmedRevision: 0)
            check.setScope(scope)
            let sample: [String: Any] = ["snapshot_id":"33333333-3333-4333-8333-333333333333", "revision":1, "as_of_seq":2, "bindings":[slot["binding"]!], "capabilities":[slot["capability"]!]]
            var accepted = true
            do { try check.appendPage(bytes(sample), requestedCursor: nil, scope: scope); _ = try check.finish(scope: scope) } catch { accepted = false }
            guard accepted == (slot["accept"] as! Bool) else { fatalError("corpus mismatch: \(slot["id"]!)") }
        }
        print("ProviderProjection: ok")
    }
}
