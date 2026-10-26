import Foundation

@main
struct PocketMemoryValidation {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pocketwiki-memory-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PocketMemoryStore(directory: root)
        let id = UUID().uuidString.lowercased()
        let events = [
            PocketMemoryIncomingEvent(event: "user-prompt-submit", sessionID: id, ingestKey: "prompt_1",
                prompt: "VLAN IoT no MikroTik", message: nil, providerID: nil, modelID: nil),
            PocketMemoryIncomingEvent(event: "assistant-response", sessionID: id, ingestKey: "answer_1",
                prompt: nil, message: "Use VLAN 30 na bridge", providerID: "lmstudio", modelID: "qwen")
        ]
        let accepted = try await store.capture(events)
        precondition(accepted == ["prompt_1", "answer_1"])
        let replay = try await store.capture(events)
        precondition(replay == accepted)
        let data = try Data(contentsOf: root.appendingPathComponent("captures/session-\(id).json"))
        let record = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition((record["messages"] as? [[String: Any]])?.count == 2)
        let recovered = try await PocketMemoryStore(directory: root).recall("MikroTik VLAN")
        precondition(recovered.context.contains("VLAN 30"))
        precondition(recovered.hits.first?.id == id)

        try await store.writeNote("Responder em portugues.")
        let localID = UUID().uuidString.lowercased()
        let local: [String: Any] = ["id": localID.uppercased(), "messages": [
            ["role": "user", "content": "PowerEdge no Zabbix", "model_id": "gpt"],
            ["role": "assistant", "content": "Monitorar iDRAC por IPMI", "model_id": "qwen"]
        ]]
        try JSONSerialization.data(withJSONObject: local).write(to: root.appendingPathComponent("session-\(localID).json"))
        _ = try await store.capture([PocketMemoryIncomingEvent(event: "user-prompt-submit", sessionID: localID,
            ingestKey: "local_duplicate_1", prompt: "PowerEdge", message: nil, providerID: nil, modelID: nil)])
        let context = try await store.recall("Zabbix PowerEdge")
        precondition(context.context.contains("Responder em portugues"))
        precondition(context.context.contains("Monitorar iDRAC"))
        precondition(context.hits.first?.source == "local")
        precondition(context.hits.count == 1)

        let invalid = PocketMemoryIncomingEvent(event: "user-prompt-submit", sessionID: "../../etc/passwd", ingestKey: "bad_1",
            prompt: "teste", message: nil, providerID: nil, modelID: nil)
        do {
            _ = try await store.capture([invalid])
            fatalError("Identificador invalido aceito")
        } catch PocketMemoryStoreError.invalidInput {}
        print("PocketMemoryStore Swift: OK")
    }
}
