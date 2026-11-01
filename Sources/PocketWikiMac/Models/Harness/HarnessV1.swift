import Foundation

enum HarnessV1 {
    static let protocolMajor = 1

    enum ModuleID: String, Codable, CaseIterable {
        case runtime, providers, threads, composer, permissions, workspaces
        case checkpoints, terminal, environments
        case orchestratorMcp = "orchestrator-mcp"
        case handoffs, memory
        case sourceControl = "source-control"
        case navigation, diagnostics
    }

    enum Scope: String, Codable, CaseIterable {
        case read, submit, approve, execute
        case contextRead = "context.read"
        case memoryPersonalRead = "memory.personal.read"
        case memoryWrite = "memory.write"
        case scmWrite = "scm.write"
        case scmMerge = "scm.merge"
    }

    struct Error: Codable, Equatable {
        let code: String
        let message: String
        let correlationID: UUID
        let retryable: Bool

        enum CodingKeys: String, CodingKey {
            case code, message, retryable
            case correlationID = "correlation_id"
        }
    }

    struct Command<Input: Codable & Equatable>: Codable, Equatable {
        let protocolMajor: Int
        let commandID: UUID
        let environmentID: UUID
        let expectedRevision: Int
        let operation: String
        let input: Input

        enum CodingKeys: String, CodingKey {
            case input, operation
            case protocolMajor = "protocol_major"
            case commandID = "command_id"
            case environmentID = "environment_id"
            case expectedRevision = "expected_revision"
        }
    }

    struct SnapshotPage<Data: Codable & Equatable>: Codable, Equatable {
        let module: ModuleID
        let data: Data
    }

    struct StreamEnvelope<Payload: Codable & Equatable>: Codable, Equatable {
        enum Delivery: String, Codable { case inline, reference }

        let protocolMajor: Int
        let eventID: UUID
        let environmentID: UUID
        let threadID: UUID?
        let seq: Int
        let committedAtMS: Int64
        let module: ModuleID
        let delivery: Delivery
        let payloadRef: UUID?
        let payload: Payload?

        enum CodingKeys: String, CodingKey {
            case module, delivery, payload
            case protocolMajor = "protocol_major"
            case eventID = "event_id"
            case environmentID = "environment_id"
            case threadID = "thread_id"
            case committedAtMS = "committed_at_ms"
            case payloadRef = "payload_ref"
            case seq
        }

        func validate() throws {
            guard protocolMajor == HarnessV1.protocolMajor, seq >= 0, committedAtMS >= 0 else {
                throw ValidationError.invalidStreamEnvelope
            }
            switch (delivery, payloadRef, payload) {
            case (.inline, nil, .some), (.reference, .some, nil): return
            default: throw ValidationError.invalidDeliveryUnion
            }
        }
    }

    enum ValidationError: Swift.Error { case invalidStreamEnvelope, invalidDeliveryUnion }

    static func validateCorpusValue(_ value: Any, schemaName: String) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        switch schemaName {
        case "command":
            guard hasOnly(object, ["protocol_major", "command_id", "environment_id", "expected_revision", "operation", "input"]),
                  object["protocol_major"] as? Int == protocolMajor,
                  uuid(object["command_id"]), uuid(object["environment_id"]),
                  let revision = object["expected_revision"] as? Int, revision >= 0,
                  let operation = object["operation"] as? String,
                  let entry = HarnessOperationRegistry.entries[operation],
                  entry.operationClass == "mutation", entry.contractStatus == "closed", !entry.implemented,
                  let input = object["input"] as? [String: Any] else { return false }
            let inputFieldNames = Set(entry.inputFields.keys)
            guard Set(input.keys).isSubset(of: inputFieldNames), entry.requiredFields.isSubset(of: Set(input.keys)) else { return false }
            return input.allSatisfy { name, fieldValue in
                guard let fieldType = entry.inputFields[name] else { return false }
                return valid(value: fieldValue, as: fieldType)
            }
        case "harnessError":
            guard hasOnly(object, ["code", "message", "correlation_id", "retryable"]),
                  let code = object["code"] as? String, errorCodes.contains(code),
                  let message = object["message"] as? String, message.utf8.count <= 1024,
                  uuid(object["correlation_id"]), object["retryable"] as? Bool != nil else { return false }
            return true
        case "snapshotEnvelope":
            guard hasOnly(object, ["module", "data"]),
                  let module = object["module"] as? String, ModuleID(rawValue: module) != nil,
                  let data = object["data"] as? [String: Any],
                  let collections = snapshotCollections[module],
                  hasOnly(data, Set(["snapshot_id", "revision", "as_of_seq", "next_cursor"] + collections)),
                  uuid(data["snapshot_id"]),
                  let revision = data["revision"] as? Int, revision >= 0,
                  let sequence = data["as_of_seq"] as? Int, sequence >= 0 else { return false }
            let requiredCollections = collections.filter { $0 != "thread" && $0 != "settings" }
            guard requiredCollections.allSatisfy({ data[$0] as? [Any] != nil }) else { return false }
            if let cursor = data["next_cursor"], ((cursor as? String)?.utf8.count ?? 513) > 512 { return false }
            return true
        case "streamEnvelope":
            guard hasOnly(object, ["protocol_major", "event_id", "environment_id", "thread_id", "seq", "committed_at_ms", "module", "delivery", "payload_ref", "payload"]),
                  object["protocol_major"] as? Int == protocolMajor,
                  uuid(object["event_id"]), uuid(object["environment_id"]),
                  object["thread_id"] == nil || uuid(object["thread_id"]),
                  let seq = object["seq"] as? Int, seq >= 0,
                  let committed = object["committed_at_ms"] as? Int64, committed >= 0,
                  let module = object["module"] as? String, ModuleID(rawValue: module) != nil,
                  let delivery = object["delivery"] as? String else { return false }
            if delivery == "inline" {
                guard let payload = object["payload"] as? [String: Any], object["payload_ref"] == nil else { return false }
                return validModuleEvent(payload, module: module)
            }
            if delivery == "reference" { return uuid(object["payload_ref"]) && object["payload"] == nil }
            return false
        case "localCredentialMetadata":
            guard hasOnly(object, ["principal_id", "environment_id", "thread_id", "scopes", "audience", "expires_at_ms"]),
                  uuid(object["principal_id"]), uuid(object["environment_id"]),
                  object["thread_id"] == nil || uuid(object["thread_id"]),
                  let scopes = object["scopes"] as? [String], Set(scopes).count == scopes.count,
                  scopes.allSatisfy({ Scope(rawValue: $0) != nil }),
                  object["audience"] as? String != nil else { return false }
            return true
        default:
            return false
        }
    }

    private static let errorCodes: Set<String> = [
        "ERR_ACTION_CHANGED", "ERR_ACTIVE_CONFIRMATION", "ERR_BOUNDARY", "ERR_BUDGET", "ERR_CAPACITY_UNKNOWN",
        "ERR_CATALOG_STALE", "ERR_COMPONENT_UNAVAILABLE", "ERR_CONFLICT", "ERR_CONTEXT_STALE", "ERR_CURSOR_EXPIRED",
        "ERR_EXPIRED", "ERR_FORBIDDEN", "ERR_FORGE_UNAVAILABLE", "ERR_GIT", "ERR_HEAD_CHANGED", "ERR_IDENTITY_CHANGED",
        "ERR_IMPORT", "ERR_INCOMPATIBLE", "ERR_INVALID", "ERR_MEMORY_UNAVAILABLE", "ERR_NOT_FOUND", "ERR_NOT_RESUMABLE",
        "ERR_OFFLINE", "ERR_PAIRING", "ERR_PATH_ESCAPE", "ERR_PROCESS", "ERR_PROTOCOL", "ERR_PROVIDER_UNAVAILABLE",
        "ERR_QUEUE_FULL", "ERR_RECOVERY_REQUIRED", "ERR_REFRESH_REUSED", "ERR_REPORT_LIMIT", "ERR_REVOKED", "ERR_SCOPE",
        "ERR_SESSION_EXPIRED", "ERR_SETTINGS_STALE", "ERR_TERMINAL_LIMIT", "ERR_TIMEOUT", "ERR_UNAVAILABLE",
        "ERR_UNCERTAIN", "ERR_UNSUPPORTED", "ERR_WORKSPACE_BUSY", "ERR_RATE_LIMIT"
    ]

    private static let snapshotCollections: [String: [String]] = [
        "runtime": ["receipts", "effects"],
        "providers": ["bindings", "capabilities"],
        "threads": ["thread", "messages", "runs", "queue", "timeline"],
        "composer": ["drafts"],
        "permissions": ["requests"],
        "workspaces": ["projects", "leases", "settings"],
        "checkpoints": ["checkpoints"],
        "terminal": ["terminals"],
        "environments": ["connections"],
        "orchestrator-mcp": ["threads"],
        "handoffs": ["lineage"],
        "memory": ["notes"],
        "source-control": ["links", "previews"],
        "navigation": ["entries", "notifications"],
        "diagnostics": ["components"]
    ]

    private static let moduleEventTypes: [String: Set<String>] = [
        "runtime": ["RuntimeReceipt", "EffectRecord", "RuntimeEvent"],
        "providers": ["ProviderBinding", "ProviderCapabilities"],
        "threads": ["ThreadState", "ConversationMessage", "QueueEntry", "RunRecord", "TimelineItem"],
        "composer": ["ComposerDraft"],
        "permissions": ["PermissionRequest"],
        "workspaces": ["ProjectRecord", "WorkspaceLease", "WorkspaceSettings"],
        "checkpoints": ["Checkpoint"],
        "terminal": ["TerminalState", "TerminalFrame"],
        "environments": ["EnvironmentConnection"],
        "orchestrator-mcp": ["MCPThreadSummary"],
        "handoffs": ["ThreadLineage"],
        "memory": ["MemoryNote"],
        "source-control": ["PullRequestLink", "ForgeAction"],
        "navigation": ["NavigationEntry", "InboxNotification"],
        "diagnostics": ["ComponentHealth"]
    ]

    private static func validModuleEvent(_ event: [String: Any], module: String) -> Bool {
        guard hasOnly(event, ["entity_type", "entity_key", "change", "value"]),
              let type = event["entity_type"] as? String, moduleEventTypes[module]?.contains(type) == true,
              let key = event["entity_key"] as? String, key.utf8.count <= 1024, isCanonicalJSON(key),
              let change = event["change"] as? String else { return false }
        if change == "delete" { return event["value"] == nil }
        if change == "upsert" { return event["value"] as? [String: Any] != nil }
        return false
    }

    private static func hasOnly(_ value: [String: Any], _ allowed: Set<String>) -> Bool {
        Set(value.keys).isSubset(of: allowed)
    }

    private static func uuid(_ value: Any?) -> Bool {
        guard let text = value as? String, let uuid = UUID(uuidString: text) else { return false }
        return uuid.uuidString.lowercased() == text.lowercased()
    }

    private static func valid(value: Any, as rawType: String) -> Bool {
        if rawType.hasSuffix("?") {
            if value is NSNull { return true }
            return valid(value: value, as: String(rawType.dropLast()))
        }
        if rawType.hasPrefix("array["), rawType.hasSuffix("]") {
            guard let values = value as? [Any] else { return false }
            let elementType = String(rawType.dropFirst(6).dropLast())
            return values.allSatisfy { valid(value: $0, as: elementType) }
        }
        if rawType.hasPrefix("enum["), rawType.hasSuffix("]") {
            let allowed = Set(rawType.dropFirst(5).dropLast().split(separator: ",").map(String.init))
            guard let text = value as? String else { return false }
            return allowed.contains(text)
        }
        switch rawType {
        case "uuid": return uuid(value)
        case "sha256": return (value as? String).map { $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil } ?? false
        case "sha1": return (value as? String).map { $0.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil } ?? false
        case "string": return value as? String != nil
        case "int": return value as? Int != nil
        case "bool": return value as? Bool != nil
        default: return value as? [String: Any] != nil
        }
    }

    private static func isCanonicalJSON(_ value: String) -> Bool {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]),
              let canonical = try? JSONSerialization.data(withJSONObject: parsed, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: canonical, encoding: .utf8) else { return false }
        return text == value
    }
}
