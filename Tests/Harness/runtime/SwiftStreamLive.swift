import Foundation

private struct RuntimeEvent: Codable, Equatable, Sendable { let entity_type: String; let entity_key: String; let change: String }
private struct Receipt: Decodable { let revision: Int }
private struct Snapshot: Decodable { let module: String }

@main struct Main {
    static func main() async throws {
        let thread = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let schemaData = try Data(contentsOf: URL(fileURLWithPath: "src/harness/contracts/harness-v1.schema.json"))
        let client = try RuntimeTransport(baseURL: URL(string: CommandLine.arguments[1])!, bearer: "test-secret")
        let stream = try client.stream(environmentID: thread, threadID: thread, afterSeq: 3, payloadType: RuntimeEvent.self, schemaData: schemaData)
        var seen = [Int]()
        for try await event in stream {
            guard event.payload?.change == "delete" else { throw RuntimeTransport.Failure.invalidResponse }
            seen.append(event.seq)
        }
        guard seen == [4] else { throw RuntimeTransport.Failure.invalidResponse }
        do {
            let bad = try client.stream(environmentID: thread, threadID: thread, afterSeq: 3, payloadType: RuntimeEvent.self, schemaData: schemaData)
            for try await _ in bad { throw RuntimeTransport.Failure.invalidArgument }
            throw RuntimeTransport.Failure.invalidArgument
        } catch RuntimeTransport.Failure.invalidResponse { }
        do {
            let forbidden = try client.stream(environmentID: thread, threadID: thread, afterSeq: 3, payloadType: RuntimeEvent.self, schemaData: schemaData)
            for try await _ in forbidden { throw RuntimeTransport.Failure.invalidArgument }
            throw RuntimeTransport.Failure.invalidArgument
        } catch RuntimeTransport.Failure.remote(let status, let error) {
            guard status == 403 && error.code == "ERR_FORBIDDEN" else { throw RuntimeTransport.Failure.invalidResponse }
        }
        let input = RuntimeTransport.DispatchInput(commandID: thread, threadID: thread, expectedRevision: 0, operation: "submit", text: "Olá", runID: nil)
        let badCommand = HarnessV1.Command(protocolMajor: 1, commandID: thread, environmentID: thread, expectedRevision: 1, operation: "runtime.dispatch", input: input)
        do {
            _ = try await client.dispatch(badCommand)
            throw RuntimeTransport.Failure.invalidResponse
        } catch RuntimeTransport.Failure.invalidArgument { }
        let command = HarnessV1.Command(protocolMajor: 1, commandID: thread, environmentID: thread, expectedRevision: 0, operation: "runtime.dispatch", input: input)
        let receipt = try await client.dispatch(command)
        guard receipt.revision == 1 else { throw RuntimeTransport.Failure.invalidResponse }
        let schema = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        _ = try await client.payload(ref: thread, schema: schema)
        do { _ = try await client.payload(ref: thread, schema: schema); throw RuntimeTransport.Failure.invalidArgument }
        catch RuntimeTransport.Failure.invalidResponse { }
        let snapshot: Snapshot = try await client.snapshot(threadID: thread, pageSize: 1, schema: schema)
        guard snapshot.module == "runtime" else { throw RuntimeTransport.Failure.invalidResponse }
        do { let _: Snapshot = try await client.snapshot(threadID: thread, pageSize: 1, schema: schema); throw RuntimeTransport.Failure.invalidArgument }
        catch RuntimeTransport.Failure.invalidResponse { }
        let hash = String(repeating: "a", count: 64)
        _ = try await client.capabilities(environmentID: thread, schemaSHA256: hash)
        do { _ = try await client.capabilities(environmentID: thread, schemaSHA256: hash); throw RuntimeTransport.Failure.invalidArgument }
        catch RuntimeTransport.Failure.invalidResponse { }
        let events = try await client.queryEvents(threadID: thread, afterSeq: 0, limit: 1, schema: schema)
        guard events.events.count == 1 else { throw RuntimeTransport.Failure.invalidResponse }
        do { _ = try await client.queryEvents(threadID: thread, afterSeq: 0, limit: 1, schema: schema); throw RuntimeTransport.Failure.invalidArgument }
        catch RuntimeTransport.Failure.invalidResponse { }
        let result = try await client.result(ref: thread, schema: schema)
        guard result.state == "accepted" else { throw RuntimeTransport.Failure.invalidResponse }
        do { _ = try await client.result(ref: thread, schema: schema); throw RuntimeTransport.Failure.invalidArgument }
        catch RuntimeTransport.Failure.invalidResponse { }
        _ = try await client.receipt(commandID: thread, environmentID: thread)
        do { _ = try await client.receipt(commandID: thread, environmentID: thread); throw RuntimeTransport.Failure.invalidArgument }
        catch RuntimeTransport.Failure.invalidResponse { }
    }
}
