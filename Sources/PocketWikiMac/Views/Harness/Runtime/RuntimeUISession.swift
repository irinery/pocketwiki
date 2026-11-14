import Combine
import Foundation

extension HarnessV1.Command: @unchecked Sendable where Input: Sendable {}
extension RuntimeTransport.DispatchInput: @unchecked Sendable {}

private struct RuntimeUIPage: Codable {
    struct Receipt: Codable { let command_id: String, receipt_id: String, payload_sha256: String; let revision: Int; let effect_id: String?, state: String, result_ref: String? }
    struct Effect: Codable { let effect_id: String, command_id: String, state: String, result_ref: String? }
    struct Body: Codable { let snapshot_id: String, revision: Int, as_of_seq: Int, next_cursor: String?; let receipts: [Receipt], effects: [Effect] }
    let module: String, data: Body
}
private struct RuntimeUIMutation: Codable, Equatable, Sendable {
    struct Value: Codable, Equatable, Sendable {
        let event_id: String?, thread_id: String?, kind: String?, effect_id: String?, command_id: String?, receipt_id: String?, payload_sha256: String?, state: String?, result_ref: String?
        let seq: Int?, revision: Int?
    }
    let entity_type: String, entity_key: String, change: String
    let value: Value?
}

@MainActor
final class RuntimeUISession: ObservableObject {
    struct Receipt: Identifiable {
        let id: String, state: String, revision: Int
        var label: String { ["accepted": "Aceito", "pending": "Pendente", "succeeded": "Concluído", "failed": "Falhou", "uncertain": "Resultado incerto"][state] ?? "Estado desconhecido" }
    }
    @Published private(set) var available = false
    @Published private(set) var error: String?
    @Published private(set) var revision = 0
    @Published private(set) var lastSeq = 0
    @Published private(set) var receipts: [Receipt] = []
    @Published private(set) var pending: HarnessV1.Command<RuntimeTransport.DispatchInput>?
    @Published var draft = ""
    private let transport: RuntimeTransport, environmentID: UUID, threadID: UUID, schemaHash: String, schemaData: Data
    private let schema: [String: Any]
    private var projection: RuntimeProjection?
    private var streamTask: Task<Void, Never>?

    init(transport: RuntimeTransport, environmentID: UUID, threadID: UUID, schemaHash: String, schemaData: Data) throws {
        guard let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else { throw RuntimeTransport.Failure.invalidArgument }
        self.transport = transport; self.environmentID = environmentID; self.threadID = threadID; self.schemaHash = schemaHash; self.schemaData = schemaData; self.schema = schema
    }
    func open() async {
        do { _ = try await transport.capabilities(environmentID: environmentID, schemaSHA256: schemaHash); await reconnect() }
        catch { available = false; self.error = "Execução durável indisponível" }
    }
    func reconnect() async {
        streamTask?.cancel(); available = false
        do {
            let p = try RuntimeProjection(schema: schema, environmentID: environmentID, threadID: threadID, pageSize: 100, confirmedRevision: revision, confirmedSeq: lastSeq)
            var cursor: String?
            repeat {
                let page: RuntimeUIPage = try await transport.snapshot(threadID: threadID, cursor: cursor, schema: try JSONSerialization.jsonObject(with: schemaData) as! [String: Any])
                try p.appendPage(JSONEncoder().encode(page), requestedCursor: cursor); cursor = page.data.next_cursor
            } while cursor != nil
            let view = try p.finish()
            let stream = try transport.stream(environmentID: environmentID, threadID: threadID, afterSeq: view.lastSeq, payloadType: RuntimeUIMutation.self, schemaData: schemaData)
            projection = p; publish(view)
            streamTask = Task { [weak self] in
                do { for try await frame in stream { guard let self, !Task.isCancelled else { return }; try await self.apply(frame) } }
                catch { guard let self, !Task.isCancelled else { return }; self.available = false; self.error = "ERR_INVALID" }
            }
        } catch { available = false; self.error = "ERR_UNAVAILABLE" }
    }
    private func publish(_ view: RuntimeProjection.View) {
        revision = view.revision; lastSeq = view.lastSeq
        receipts = view.receipts.compactMap { key, value in
            guard let state = value["state"] as? String, let revision = value["revision"] as? Int else { return nil }
            return Receipt(id: key, state: state, revision: revision)
        }.sorted { $0.id < $1.id }
        available = true; error = nil
    }
    private func apply(_ frame: HarnessV1.StreamEnvelope<RuntimeUIMutation>) async throws {
        var object: [String: Any] = ["protocol_major": frame.protocolMajor, "event_id": frame.eventID.uuidString.lowercased(), "environment_id": frame.environmentID.uuidString.lowercased(), "thread_id": threadID.uuidString.lowercased(), "seq": frame.seq, "committed_at_ms": frame.committedAtMS, "module": "runtime", "delivery": frame.delivery.rawValue]
        var payload: Data?
        if let inline = frame.payload { object["payload"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inline)) }
        if let ref = frame.payloadRef { object["payload_ref"] = ref.uuidString.lowercased(); payload = try await transport.payload(ref: ref, schema: try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]) }
        guard let projection else { throw RuntimeTransport.Failure.invalidResponse }
        try projection.bufferEvent(JSONSerialization.data(withJSONObject: object), resolvedPayload: payload)
        publish(try projection.finish())
    }
    func submit() async {
        guard available, pending == nil, !draft.isEmpty, draft.utf8.count <= 32768 else { return }
        let id = UUID(), text = draft
        let input = RuntimeTransport.DispatchInput(commandID: id, threadID: threadID, expectedRevision: revision, operation: "submit", text: text, runID: nil)
        let command = HarnessV1.Command(protocolMajor: 1, commandID: id, environmentID: environmentID, expectedRevision: revision, operation: "runtime.dispatch", input: input)
        pending = command
        do { let receipt = try await transport.dispatch(copyCommand(command)); pending = nil; merge(receipt); if draft == text { draft = "" } }
        catch { self.error = "Não foi possível confirmar o comando; consulte ou repita a mesma intenção." }
    }
    func resolvePending() async {
        guard let pending else { return }
        do { let receipt = try await transport.receipt(commandID: pending.commandID, environmentID: environmentID); self.pending = nil; merge(receipt) }
        catch { self.error = "Não foi possível consultar o comando pendente." }
    }
    func retryPending() async {
        guard let pending else { return }
        do { let receipt = try await transport.dispatch(copyCommand(pending)); self.pending = nil; merge(receipt) }
        catch { self.error = "Não foi possível repetir o comando pendente." }
    }
    private func copyCommand(_ command: HarnessV1.Command<RuntimeTransport.DispatchInput>) -> HarnessV1.Command<RuntimeTransport.DispatchInput> {
        let input = command.input
        return HarnessV1.Command(protocolMajor: command.protocolMajor, commandID: command.commandID, environmentID: command.environmentID, expectedRevision: command.expectedRevision, operation: command.operation, input: RuntimeTransport.DispatchInput(commandID: input.commandID, threadID: input.threadID, expectedRevision: input.expectedRevision, operation: input.operation, text: input.text, runID: input.runID))
    }
    private func merge(_ receipt: RuntimeTransport.HTTPReceipt) {
        let key = receipt.commandID.uuidString.lowercased()
        if let previous = receipts.first(where: { $0.id == key }), previous.revision >= receipt.revision { return }
        receipts.removeAll { $0.id == key }; receipts.append(Receipt(id: key, state: receipt.state, revision: receipt.revision))
    }
}
