import Foundation

@MainActor final class StreamFixture {
    var continuation: AsyncThrowingStream<Data, Error>.Continuation!
    var displayContinuation: CheckedContinuation<Data, Never>?
    var payloadContinuation: CheckedContinuation<Data, Never>?
    var calls: [String] = []
    let first: Data
    let display: Data
    let event: Data
    let reference: Data
    let payload: Data
    init() throws {
        let binding: [String: Any] = ["binding_id":"11111111-1111-4111-8111-111111111111","provider_id":"openai","account_ref":"a","model_id":"m","mode":"inference","catalog_revision":1,"capability_id":"22222222-2222-4222-8222-222222222222"]
        let capability: [String: Any] = ["capability_id":"22222222-2222-4222-8222-222222222222","version":1,"stream_text":false,"steer":false,"interrupt":false,"rollback":false,"native_fork":false,"tools":false,"questions":false,"plans":false,"resume":false]
        var preBinding = binding; preBinding["model_id"] = "preliminary"
        let base: [String: Any] = ["snapshot_id":"33333333-3333-4333-8333-333333333333","revision":1,"as_of_seq":2,"bindings":[binding],"capabilities":[capability]]
        var preliminary = base; preliminary["bindings"] = [preBinding]
        func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        first = try bytes(preliminary); display = try bytes(base)
        var changed = binding; changed["model_id"] = "stream"
        let p: [String: Any] = ["entity_type":"ProviderBinding","entity_key":"\"11111111-1111-4111-8111-111111111111\"","change":"upsert","value":changed]
        var e: [String: Any] = ["protocol_major":1,"event_id":"44444444-4444-4444-8444-444444444444","environment_id":"55555555-5555-4555-8555-555555555555","seq":3,"committed_at_ms":1,"module":"providers","delivery":"inline","payload":p]
        payload = try bytes(p); event = try bytes(e)
        e.removeValue(forKey: "payload");e["seq"] = 4;e["event_id"] = "44444444-4444-4444-8444-444444444445";e["delivery"] = "reference";e["payload_ref"] = "66666666-6666-4666-8666-666666666666";reference = try bytes(e)
    }
    func snapshot(_ cursor: String?, _ size: Int) async -> Data {
        calls.append("snapshot")
        if calls.filter({$0 == "snapshot"}).count == 1 { return first }
        return await withCheckedContinuation { displayContinuation = $0 }
    }
    func open(_ after: Int) -> ProviderStreamFirst.Stream {
        calls.append("stream:\(after)")
        let stream = AsyncThrowingStream<Data, Error> { self.continuation = $0 }
        return .init(events: stream, cancel: { self.continuation.finish() })
    }
    func getPayload(_ ref: String) async -> Data { await withCheckedContinuation { payloadContinuation = $0 } }
}

@main struct ProviderStreamFirstRunner {
    @MainActor static func wait(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
        fatalError("condition did not become true")
    }
    @MainActor static func main() async throws {
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let fixture = try StreamFixture(), env = UUID(uuidString:"55555555-5555-4555-8555-555555555555")!
        var views: [ProviderProjection.View?] = []
        let ports = ProviderStreamFirst.Ports(snapshot:{ cursor,size in await fixture.snapshot(cursor,size) },openStream:{ after in fixture.open(after) },payload:{ ref in await fixture.getPayload(ref) })
        let client = try ProviderStreamFirst(schema:schema,environmentID:env,pageSize:100,ports:ports,onView:{ views.append($0) })
        client.setScope(.init(principal:"alice",generation:"1"))
        let start=Task { try await client.start(pageSize:100) }
        await wait { fixture.displayContinuation != nil }
        guard fixture.calls == ["snapshot","stream:2","snapshot"], views.allSatisfy({$0 == nil}) else { fatalError("stream/snapshot ordering") }
        fixture.continuation.yield(fixture.event); await Task.yield()
        fixture.displayContinuation?.resume(returning:fixture.display);fixture.displayContinuation=nil
        try await start.value
        await wait { views.last??.lastSeq == 3 }
        guard views.last??.bindings["11111111-1111-4111-8111-111111111111"]?["model_id"] as? String == "stream" else { fatalError("buffered event lost") }
        fixture.continuation.yield(fixture.reference)
        await wait { fixture.payloadContinuation != nil }
        client.setScope(nil)
        fixture.payloadContinuation?.resume(returning:fixture.payload);fixture.payloadContinuation=nil
        await Task.yield();await Task.yield()
        guard views.last! == nil else { fatalError("stale payload published") }
        do { try await client.start(pageSize:100);fatalError("inactive accepted") } catch ProviderStreamFirst.Failure.inactive { }
        let eofFixture = try StreamFixture(); var eofViews: [ProviderProjection.View?] = []
        let eofPorts = ProviderStreamFirst.Ports(snapshot:{ cursor,size in await eofFixture.snapshot(cursor,size) },openStream:{ after in eofFixture.open(after) },payload:{ ref in await eofFixture.getPayload(ref) })
        let eofClient = try ProviderStreamFirst(schema:schema,environmentID:env,pageSize:100,ports:eofPorts,onView:{ eofViews.append($0) })
        eofClient.setScope(.init(principal:"alice",generation:"1"))
        let eofStart=Task { try await eofClient.start(pageSize:100) }
        await wait { eofFixture.displayContinuation != nil };eofFixture.displayContinuation?.resume(returning:eofFixture.display);eofFixture.displayContinuation=nil
        try await eofStart.value;guard eofViews.last! != nil else { fatalError("missing view") }
        eofFixture.continuation.finish();await wait { eofViews.last! == nil }
        do { try await eofClient.start(pageSize:100);fatalError("EOF did not revoke") } catch ProviderStreamFirst.Failure.inactive { }
        print("ProviderStreamFirst: ok")
    }
}
