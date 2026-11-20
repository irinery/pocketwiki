import Foundation

@main struct ProviderProjectionRunner {
    @MainActor static func main() throws {
        let schemaData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let schema = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        let environment = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let scopeInput = ProviderProjection.Scope(principal: "alice", generation: "1")
        let projection = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        let scope = try projection.beginRefresh(projection.setScope(scopeInput))
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
        let conflictScope = try conflictProjection.beginRefresh(conflictProjection.setScope(scopeInput))
        try conflictProjection.appendPage(bytes(first), requestedCursor: nil, scope: conflictScope)
        try conflictProjection.bufferEvent(bytes(event), scope: conflictScope)
        var conflicting = event; conflicting["seq"] = 4
        do { try conflictProjection.bufferEvent(bytes(conflicting), scope: conflictScope); fatalError("conflicting replay accepted") } catch ProviderProjection.Failure.invalidEvent { }
        let stale = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 2)
        let staleScope = try stale.beginRefresh(stale.setScope(scopeInput))
        do { try stale.appendPage(bytes(first), requestedCursor: nil, scope: staleScope); fatalError("stale snapshot accepted") } catch ProviderProjection.Failure.invalidPage { }
        let bob = ProviderProjection.Scope(principal: "bob", generation: "1")
        let bob2 = ProviderProjection.Scope(principal: "bob", generation: "2")
        let isolated = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        do { try isolated.appendPage(bytes(first), requestedCursor: nil); fatalError("unscoped accepted") } catch ProviderProjection.Failure.inactiveScope { }
        let isolatedScope = try isolated.beginRefresh(isolated.setScope(scopeInput))
        try isolated.appendPage(bytes(first), requestedCursor: nil, scope: isolatedScope)
        try isolated.bufferEvent(bytes(event), scope: isolatedScope)
        let bobTicket = try isolated.beginRefresh(isolated.setScope(bob))
        do { try isolated.appendPage(bytes(second), requestedCursor: "cursor", scope: isolatedScope); fatalError("stale page accepted") } catch ProviderProjection.Failure.inactiveScope { }
        do { _ = try isolated.finish(scope: bobTicket); fatalError("old snapshot survived") } catch ProviderProjection.Failure.incomplete { }
        try isolated.appendPage(bytes(first), requestedCursor: nil, scope: bobTicket)
        try isolated.appendPage(bytes(second), requestedCursor: "cursor", scope: bobTicket)
        guard try isolated.finish(scope: bobTicket).lastSeq == 2 else { fatalError("old event survived") }
        let bob2Ticket = try isolated.beginRefresh(isolated.setScope(bob2))
        do { _ = try isolated.finish(scope: bobTicket); fatalError("old generation accepted") } catch ProviderProjection.Failure.inactiveScope { }
        do { _ = try isolated.finish(scope: bob2Ticket); fatalError("old generation state survived") } catch ProviderProjection.Failure.incomplete { }
        isolated.setScope(nil)
        do { _ = try isolated.finish(scope: bob2Ticket); fatalError("inactive scope accepted") } catch ProviderProjection.Failure.inactiveScope { }
        let same = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        let oldTicket = try same.beginRefresh(same.setScope(scopeInput))
        try same.appendPage(bytes(first), requestedCursor: nil, scope: oldTicket)
        try same.bufferEvent(bytes(event), scope: oldTicket)
        same.setScope(nil)
        let newTicket = try same.beginRefresh(same.setScope(scopeInput))
        do { try same.appendPage(bytes(second), requestedCursor: "cursor", scope: oldTicket); fatalError("old page revived") } catch ProviderProjection.Failure.inactiveScope { }
        do { try same.bufferEvent(bytes(event), scope: oldTicket); fatalError("old event revived") } catch ProviderProjection.Failure.inactiveScope { }
        do { _ = try same.finish(scope: oldTicket); fatalError("old read revived") } catch ProviderProjection.Failure.inactiveScope { }
        try same.appendPage(bytes(first), requestedCursor: nil, scope: newTicket)
        try same.appendPage(bytes(second), requestedCursor: "cursor", scope: newTicket)
        guard try same.finish(scope: newTicket).lastSeq == 2 else { fatalError("old buffered event revived") }
        let latest = try same.beginRefresh(same.setScope(scopeInput))
        do { _ = try same.finish(scope: newTicket); fatalError("same-value activation reused ticket") } catch ProviderProjection.Failure.inactiveScope { }
        do { _ = try same.finish(scope: latest); fatalError("same-value activation kept cache") } catch ProviderProjection.Failure.incomplete { }
        let refreshProjection = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        let authority = refreshProjection.setScope(scopeInput)!
        let refreshA = try refreshProjection.beginRefresh(authority)
        let refreshB = try refreshProjection.beginRefresh(authority)
        guard !refreshProjection.isCurrent(refreshA), refreshProjection.isCurrent(refreshB) else { fatalError("refresh ticket check failed") }
        try refreshProjection.appendPage(bytes(first), requestedCursor: nil, scope: refreshB)
        do { try refreshProjection.appendPage(bytes(first), requestedCursor: nil, scope: refreshA); fatalError("old first page accepted") } catch ProviderProjection.Failure.inactiveScope { }
        do { try refreshProjection.bufferEvent(bytes(event), scope: refreshA); fatalError("old stream accepted") } catch ProviderProjection.Failure.inactiveScope { }
        var refEvent = event; refEvent.removeValue(forKey: "payload"); refEvent["delivery"] = "reference"; refEvent["payload_ref"] = "66666666-6666-4666-8666-666666666666"
        do { try refreshProjection.bufferEvent(bytes(refEvent), resolvedPayload: bytes(payload), scope: refreshA); fatalError("old payload accepted") } catch ProviderProjection.Failure.inactiveScope { }
        do { _ = try refreshProjection.finish(scope: refreshA); fatalError("old read accepted") } catch ProviderProjection.Failure.inactiveScope { }
        try refreshProjection.appendPage(bytes(second), requestedCursor: "cursor", scope: refreshB)
        guard try refreshProjection.finish(scope: refreshB).lastSeq == 2 else { fatalError("refresh fence failed") }
        let floorProjection = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 1, confirmedRevision: 0)
        let floorAuthority = floorProjection.setScope(scopeInput)!
        let floorA = try floorProjection.beginRefresh(floorAuthority)
        var highFirst = first; highFirst["revision"] = 10; highFirst["as_of_seq"] = 20
        var highSecond = second; highSecond["revision"] = 10; highSecond["as_of_seq"] = 20
        try floorProjection.appendPage(bytes(highFirst), requestedCursor: nil, scope: floorA)
        try floorProjection.appendPage(bytes(highSecond), requestedCursor: "cursor", scope: floorA)
        _ = try floorProjection.finish(scope: floorA)
        let floorB = try floorProjection.beginRefresh(floorAuthority)
        do { try floorProjection.appendPage(bytes(first), requestedCursor: nil, scope: floorB); fatalError("older refresh accepted") } catch ProviderProjection.Failure.invalidPage { }
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        for slot in corpus["slots"] as! [[String: Any]] {
            let check = try ProviderProjection(schema: schema, environmentID: environment, pageSize: 100, confirmedRevision: 0)
            let checkScope = try check.beginRefresh(check.setScope(scopeInput))
            let sample: [String: Any] = ["snapshot_id":"33333333-3333-4333-8333-333333333333", "revision":1, "as_of_seq":2, "bindings":[slot["binding"]!], "capabilities":[slot["capability"]!]]
            var accepted = true
            do { try check.appendPage(bytes(sample), requestedCursor: nil, scope: checkScope); _ = try check.finish(scope: checkScope) } catch { accepted = false }
            guard accepted == (slot["accept"] as! Bool) else { fatalError("corpus mismatch: \(slot["id"]!)") }
        }
        print("ProviderProjection: ok")
    }
}
