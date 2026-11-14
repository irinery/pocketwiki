import Foundation

private struct Mutation: Codable, Equatable, Sendable {
    struct Value: Codable, Equatable, Sendable {
        let event_id: String?
        let thread_id: String?
        let seq: Int?
        let kind: String?
        let effect_id: String?
        let command_id: String?
        let receipt_id: String?
        let payload_sha256: String?
        let revision: Int?
        let state: String?
        let result_ref: String?
    }
    let entity_type: String
    let entity_key: String
    let change: String
    let value: Value?
}
private struct Page: Decodable { let module: String }

@main struct Main {
    static func main() async throws {
        guard CommandLine.arguments.count == 6, let bearer = readLine(),
              let url = URL(string: CommandLine.arguments[1]),
              let environment = UUID(uuidString: CommandLine.arguments[2]),
              let thread = UUID(uuidString: CommandLine.arguments[3]),
              let command = UUID(uuidString: CommandLine.arguments[4]) else { throw RuntimeTransport.Failure.invalidArgument }
        let schemaData = try Data(contentsOf: URL(fileURLWithPath: "src/harness/contracts/harness-v1.schema.json"))
        let schema = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        let client = try RuntimeTransport(baseURL: url, bearer: bearer)
        _ = try await client.capabilities(environmentID: environment, schemaSHA256: CommandLine.arguments[5])
        let receipt = try await client.receipt(commandID: command, environmentID: environment)
        guard receipt.state == "succeeded" else { throw RuntimeTransport.Failure.invalidResponse }
        let page: Page = try await client.snapshot(threadID: thread, pageSize: 1, schema: schema)
        guard page.module == "runtime" else { throw RuntimeTransport.Failure.invalidResponse }
        let stream = try client.stream(environmentID: environment, threadID: thread, afterSeq: 0, payloadType: Mutation.self, schemaData: schemaData)
        var found = false
        for try await item in stream {
            if item.payload?.entity_type == "RuntimeEvent", item.payload?.value?.kind == "effect_finished" { found = true; break }
        }
        guard found else { throw RuntimeTransport.Failure.invalidResponse }
    }
}
