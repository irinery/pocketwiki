import Foundation

private struct RuntimeEvent: Codable, Equatable, Sendable { let kind: String }
private struct Receipt: Decodable { let revision: Int }

@main struct Main {
    static func main() async throws {
        let thread = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let client = try RuntimeTransport(baseURL: URL(string: CommandLine.arguments[1])!, bearer: "test-secret")
        let stream = try client.stream(environmentID: thread, threadID: thread, afterSeq: 3, payloadType: RuntimeEvent.self)
        var seen = [Int]()
        for try await event in stream {
            guard event.payload?.kind == "effect_finished" else { throw RuntimeTransport.Failure.invalidResponse }
            seen.append(event.seq)
        }
        guard seen == [4] else { throw RuntimeTransport.Failure.invalidResponse }
        do {
            let bad = try client.stream(environmentID: thread, threadID: thread, afterSeq: 3, payloadType: RuntimeEvent.self)
            for try await _ in bad { throw RuntimeTransport.Failure.invalidArgument }
            throw RuntimeTransport.Failure.invalidArgument
        } catch RuntimeTransport.Failure.invalidResponse { }
        do {
            let forbidden = try client.stream(environmentID: thread, threadID: thread, afterSeq: 3, payloadType: RuntimeEvent.self)
            for try await _ in forbidden { throw RuntimeTransport.Failure.invalidArgument }
            throw RuntimeTransport.Failure.invalidArgument
        } catch RuntimeTransport.Failure.remote(let status, let error) {
            guard status == 403 && error.code == "ERR_FORBIDDEN" else { throw RuntimeTransport.Failure.invalidResponse }
        }
        let input = RuntimeTransport.DispatchInput(commandID: thread, threadID: thread, expectedRevision: 0, operation: "submit", text: "Olá", runID: nil)
        let badCommand = HarnessV1.Command(protocolMajor: 1, commandID: thread, environmentID: thread, expectedRevision: 1, operation: "runtime.dispatch", input: input)
        do {
            let _: Receipt = try await client.dispatch(badCommand)
            throw RuntimeTransport.Failure.invalidResponse
        } catch RuntimeTransport.Failure.invalidArgument { }
        let command = HarnessV1.Command(protocolMajor: 1, commandID: thread, environmentID: thread, expectedRevision: 0, operation: "runtime.dispatch", input: input)
        let receipt: Receipt = try await client.dispatch(command)
        guard receipt.revision == 1 else { throw RuntimeTransport.Failure.invalidResponse }
    }
}
