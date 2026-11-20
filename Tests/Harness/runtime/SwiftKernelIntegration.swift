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
private struct Page: Codable {
    struct Receipt: Codable {
        let command_id: String, receipt_id: String, payload_sha256: String
        let revision: Int
        let effect_id: String?, state: String, result_ref: String?
    }
    struct Effect: Codable { let effect_id: String, command_id: String, state: String, result_ref: String? }
    struct Data: Codable {
        let snapshot_id: String, revision: Int, as_of_seq: Int, next_cursor: String?
        let receipts: [Receipt], effects: [Effect]
    }
    let module: String
    let data: Data
}

@main struct Main {
    static func main() async throws {
        guard CommandLine.arguments.count == 7, let bearer = readLine(),
              let url = URL(string: CommandLine.arguments[1]),
              let environment = UUID(uuidString: CommandLine.arguments[2]),
              let thread = UUID(uuidString: CommandLine.arguments[3]),
              let command = UUID(uuidString: CommandLine.arguments[4]) else { throw RuntimeTransport.Failure.invalidArgument }
        let secondCommand = CommandLine.arguments[6]
        let schemaData = try Data(contentsOf: URL(fileURLWithPath: "src/harness/contracts/harness-v1.schema.json"))
        let schema = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        let client = try RuntimeTransport(baseURL: url, bearer: bearer)
        _ = try await client.capabilities(environmentID: environment, schemaSHA256: CommandLine.arguments[5])
        let receipt = try await client.receipt(commandID: command, environmentID: environment)
        guard receipt.state == "succeeded" else { throw RuntimeTransport.Failure.invalidResponse }
        // Fresh projection represents a cleared cache; no view is published before both pages arrive.
        let projection = try RuntimeProjection(schema: schema, environmentID: environment, threadID: thread, pageSize: 1, confirmedRevision: 0)
        let first: Page = try await client.snapshot(threadID: thread, pageSize: 1, schema: schema)
        guard first.module == "runtime", let cursor = first.data.next_cursor else { throw RuntimeTransport.Failure.invalidResponse }
        try projection.appendPage(JSONEncoder().encode(first), requestedCursor: nil)
        FileHandle.standardOutput.write(Data("PAGE1\n".utf8))
        guard let line = readLine(), let lineData = line.data(using: .utf8),
              let frames = try JSONSerialization.jsonObject(with: lineData) as? [String], !frames.isEmpty else { throw RuntimeTransport.Failure.invalidResponse }
        let second: Page = try await client.snapshot(threadID: thread, pageSize: 1, cursor: cursor, schema: schema)
        try projection.appendPage(JSONEncoder().encode(second), requestedCursor: cursor)
        for (index, frame) in frames.enumerated() {
            guard let data = Data(base64Encoded: frame) else { throw RuntimeTransport.Failure.invalidResponse }
            try projection.bufferEvent(data)
            if index == 0 { try projection.bufferEvent(data) }
        }
        let view = try projection.finish()
        guard view.receipts.count == 2, view.effects.count == 2, view.receipts[secondCommand] != nil,
              view.lastSeq > view.asOfSeq, view.appliedEventCount == frames.count else { throw RuntimeTransport.Failure.invalidResponse }
        let stream = try client.stream(environmentID: environment, threadID: thread, afterSeq: 0, payloadType: Mutation.self, schemaData: schemaData)
        var found = false
        for try await item in stream {
            if item.payload?.entity_type == "RuntimeEvent", item.payload?.value?.kind == "effect_finished" { found = true; break }
        }
        guard found else { throw RuntimeTransport.Failure.invalidResponse }
    }
}
