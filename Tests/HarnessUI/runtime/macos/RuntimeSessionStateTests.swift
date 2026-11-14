import Combine
import Foundation

@main struct Main {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3, let url = URL(string: CommandLine.arguments[1]) else { fatalError("arguments") }
        let scenario = CommandLine.arguments[2], id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let schema = try Data(contentsOf: URL(fileURLWithPath: "src/harness/contracts/harness-v1.schema.json"))
        let transport = try RuntimeTransport(baseURL: url, bearer: "fixture")
        let commandIDs = [UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, UUID(uuidString: "33333333-3333-4333-8333-333333333333")!]
        var commandIndex = 0
        let session = try RuntimeUISession(transport: transport, environmentID: id, threadID: id, schemaHash: String(repeating: "a", count: 64), schemaData: schema, newCommandID: { let value = commandIDs[commandIndex]; commandIndex += 1; return value })
        session.draft = "rascunho preservado"
        await session.open()
        if scenario == "eof" {
            for await error in session.$error.values where error == "ERR_UNAVAILABLE" { break }
            guard !session.available, session.draft == "rascunho preservado", session.pending == nil else { fatalError("EOF deixou UI ativa ou perdeu rascunho") }
        } else {
            guard session.available else { fatalError("sessão indisponível") }
            await session.submit()
            guard session.draft == "rascunho preservado", !session.pendingBusy else { fatalError("rascunho ou bloqueio incorreto") }
            if scenario == "409" || scenario == "403" || scenario == "404" {
                guard session.pending == nil else { fatalError("recusa inequívoca reteve intenção") }
                await session.submit()
                guard session.pending == nil else { fatalError("recusa seguinte reteve intenção") }
            } else {
                guard let first = session.pending else { fatalError("falha ambígua perdeu intenção") }
                await session.submit()
                guard session.pending?.commandID == first.commandID, session.pending?.input == first.input else { fatalError("falha ambígua criou intenção nova") }
            }
        }
        print("session \(scenario) passou")
    }
}
