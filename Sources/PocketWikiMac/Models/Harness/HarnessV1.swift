import Foundation
import CoreFoundation

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

    static func validateCorpusValue(_ value: Any, schemaName: String, document: [String: Any], operationName: String? = nil) -> Bool {
        guard let definitions = document["$defs"] as? [String: Any],
              let definition = definitions[schemaName] as? [String: Any],
              validate(value, against: definition, definitions: definitions) else { return false }
        var errors: [String] = []
        validateSemantics(value, errors: &errors)
        if let operationName { checkOperationInput(operationName, value: value, definitions: definitions, errors: &errors) }
        guard schemaName == "command", let command = value as? [String: Any] else { return errors.isEmpty }
        guard let operation = command["operation"] as? String,
              let entry = HarnessOperationRegistry.entries[operation],
              entry.operationClass == "mutation", entry.contractStatus == "closed", !entry.implemented else { return false }
        if let input = command["input"] {
            checkOperationInput(operation, value: input, definitions: definitions, errors: &errors)
            if operation == "runtime.dispatch", let inputObject = input as? [String: Any] {
                guard inputObject["command_id"] as? String == command["command_id"] as? String,
                      inputObject["expected_revision"] as? Int == command["expected_revision"] as? Int else { return false }
            }
        }
        return errors.isEmpty
    }

    private static func validateSemantics(_ value: Any, errors: inout [String]) {
        if let object = value as? [String: Any] {
            if let requestID = object["request_id"], requestID is String,
               let action = object["action"] as? [String: Any],
               let kind = object["kind"] as? String,
               let options = object["options"] {
                guard kind == action["kind"] as? String else { errors.append("PermissionRequest.kind mismatch"); return }
                let expected: Any = kind == "question" ? (action["options"] ?? []) : []
                guard jsonEqual(options, expected) else { errors.append("PermissionRequest.options mismatch"); return }
            }
            for child in object.values { validateSemantics(child, errors: &errors) }
        } else if let array = value as? [Any] {
            for child in array { validateSemantics(child, errors: &errors) }
        }
    }

    private static func checkOperationInput(_ operation: String, value: Any, definitions: [String: Any], errors: inout [String]) {
        guard let object = value as? [String: Any] else { errors.append("operation input must be object"); return }
        func has(_ key: String) -> Bool { object.keys.contains(key) }
        func require(_ condition: Bool) { if !condition { errors.append("\(operation) input condition failed") } }
        switch operation {
        case "threads.message":
            require(has("prepared_id") == has("manifest_sha256"))
            let action = object["action"] as? String ?? ""
            require(!["enqueue", "edit", "steer"].contains(action) || !(object["text"] as? String ?? "").isEmpty)
        case "runtime.dispatch":
            let action = object["operation"] as? String
            let text = object["text"] as? String ?? ""
            require(action == "submit" ? (!has("run_id") && !text.isEmpty) : has("run_id"))
        case "permissions.respond":
            let answer = object["answer"] as? String
            require(answer != "answer" || !(object["text"] as? String ?? "").isEmpty || !(object["option_id"] as? String ?? "").isEmpty)
            require(answer == "answer" || !has("option_id"))
        case "workspaces.prepare":
            let mode = object["mode"] as? String
            require(mode == "scratch" ? !has("project_id") : has("project_id"))
            require(mode != "worktree" || (has("base_sha") && has("branch")))
            require(mode != "worktree" || isHarnessBranch(object["branch"] as? String ?? ""))
        case "checkpoints.diff":
            let scope = object["scope"] as? String
            require(scope == "turn" ? (has("run_id") && !has("base_sha")) : (has("base_sha") && !has("run_id")))
        case "terminal.open":
            require((object["kind"] as? String) != "task" || has("approval_id"))
        case "mcp.thread.call":
            let tool = object["tool"] as? String ?? ""
            let forbidden: [String: [String]] = [
                "thread.list": ["command_id", "thread_id", "text", "after_seq", "through_seq", "binding_id", "message_id", "queue_revision"],
                "thread.read": ["command_id", "project_id", "text", "binding_id", "message_id", "queue_revision"],
                "thread.start": ["thread_id", "after_seq", "through_seq", "cursor", "queue_revision"],
                "thread.send": ["project_id", "after_seq", "through_seq", "cursor"],
                "thread.interrupt": ["project_id", "text", "after_seq", "through_seq", "cursor", "binding_id", "message_id"]
            ]
            require((forbidden[tool] ?? []).allSatisfy { !has($0) })
            let required: [String: [String]] = [
                "thread.start": ["command_id", "text", "binding_id", "message_id"],
                "thread.send": ["command_id", "thread_id", "text", "binding_id", "message_id", "queue_revision"],
                "thread.interrupt": ["command_id", "thread_id", "queue_revision"],
                "thread.read": ["thread_id"], "thread.list": []
            ]
            require((required[tool] ?? []).allSatisfy(has))
            if tool == "thread.start" || tool == "thread.send" { require(!(object["text"] as? String ?? "").isEmpty) }
            if tool == "thread.read" { require(!has("cursor") || has("through_seq")) }
        case "source_control.preview":
            let keys = ["host", "repository", "operation", "pr_number", "head_sha", "body", "title", "base_branch", "head_branch", "review_event", "merge_method"]
            let preview = object.filter { keys.contains($0.key) }
            require(definitions["ForgePreview"].map { validate(preview, against: $0 as! [String: Any], definitions: definitions) } ?? false)
        case "navigation.update":
            require((object["action"] as? String == "reorder") == has("before_thread_id"))
        case "navigation.list":
            require(has("after_position") == has("after_id"))
            require((has("after_id") || has("after_position")) == has("revision"))
        default: break
        }
    }

    private static func validate(_ value: Any, against rule: [String: Any], definitions: [String: Any], parentValue: Any? = nil) -> Bool {
        if let ref = rule["$ref"] as? String, ref.hasPrefix("#/$defs/"),
           let target = definitions[String(ref.dropFirst("#/$defs/".count))] as? [String: Any] {
            return validate(value, against: target, definitions: definitions, parentValue: parentValue)
        }
        if let oneOf = rule["oneOf"] as? [[String: Any]], oneOf.filter({ validate(value, against: $0, definitions: definitions, parentValue: parentValue) }).count != 1 { return false }
        if let anyOf = rule["anyOf"] as? [[String: Any]], !anyOf.contains(where: { validate(value, against: $0, definitions: definitions, parentValue: parentValue) }) { return false }
        if let forbidden = rule["not"] as? [String: Any], validate(value, against: forbidden, definitions: definitions, parentValue: parentValue) { return false }
        if let type = rule["type"] as? String {
            switch type {
            case "object":
                guard let object = value as? [String: Any] else { return false }
                let properties = rule["properties"] as? [String: Any] ?? [:]
                let required = rule["required"] as? [String] ?? []
                guard required.allSatisfy({ object.keys.contains($0) }) else { return false }
                if rule["additionalProperties"] as? Bool == false && !Set(object.keys).isSubset(of: Set(properties.keys)) { return false }
                for (key, child) in properties where object.keys.contains(key) {
                    guard let childRule = child as? [String: Any], let childValue = object[key], validate(childValue, against: childRule, definitions: definitions, parentValue: object) else { return false }
                }
            case "array":
                guard let array = value as? [Any] else { return false }
                if let min = rule["minItems"] as? Int, array.count < min { return false }
                if let max = rule["maxItems"] as? Int, array.count > max { return false }
                if rule["uniqueItems"] as? Bool == true && Set(array.map(jsonFingerprint)).count != array.count { return false }
                if let child = rule["items"] as? [String: Any], !array.allSatisfy({ validate($0, against: child, definitions: definitions, parentValue: array) }) { return false }
            case "string":
                guard let string = value as? String else { return false }
                if let min = rule["minLength"] as? Int, string.unicodeScalars.count < min { return false }
                if let max = rule["maxLength"] as? Int, string.unicodeScalars.count > max { return false }
                if let min = rule["x-minUtf8Bytes"] as? Int, string.utf8.count < min { return false }
                var maxBytes = rule["x-maxUtf8Bytes"] as? Int
                if let conditional = rule["x-maxUtf8BytesBy"] as? [String: Any], let parent = parentValue as? [String: Any] {
                    for (parentField, variantsValue) in conditional {
                        guard let discriminator = parent[parentField] as? String,
                              let variants = variantsValue as? [String: Any],
                              let limit = variants[discriminator] as? Int else { continue }
                        maxBytes = min(maxBytes ?? limit, limit)
                    }
                }
                if let maxBytes, string.utf8.count > maxBytes { return false }
                if let pattern = rule["pattern"] as? String, string.range(of: pattern, options: .regularExpression) == nil { return false }
                if rule["format"] as? String == "uuid" && !uuid(string) { return false }
                if rule["x-format"] as? String == "jcs" && !isCanonicalJSON(string) { return false }
                if rule["x-format"] as? String == "base64" {
                    guard let decoded = decodeBase64(string) else { return false }
                    if let maxDecoded = rule["x-maxBase64DecodedBytes"] as? Int, decoded.count > maxDecoded { return false }
                }
                if rule["x-format"] as? String == "base64url32" && !isBase64URL32(string) { return false }
                if rule["x-format"] as? String == "basename" && !isBasename(string) { return false }
                if rule["x-format"] as? String == "relative-path" && !isSafeRelativePath(string) { return false }
                if rule["x-format"] as? String == "pairing-endpoint" && !isPairingEndpoint(string) { return false }
                if rule["x-format"] as? String == "hostname" && !isHostname(string) { return false }
                if rule["x-format"] as? String == "git-branch" && !isHarnessBranch(string) { return false }
            case "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded(.towardZero) == number.doubleValue, abs(number.doubleValue) <= 9_007_199_254_740_991 else { return false }
                if let minimum = rule["minimum"] as? NSNumber, number.doubleValue < minimum.doubleValue { return false }
                if let maximum = rule["maximum"] as? NSNumber, number.doubleValue > maximum.doubleValue { return false }
            case "boolean":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            case "null":
                guard value is NSNull else { return false }
            default: return false
            }
        }
        if let constant = rule["const"], !jsonEqual(value, constant) { return false }
        if let enumeration = rule["enum"] as? [Any], !enumeration.contains(where: { jsonEqual(value, $0) }) { return false }
        return true
    }

    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        jsonFingerprint(lhs) == jsonFingerprint(rhs)
    }

    private static func jsonFingerprint(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return "<invalid>" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeBase64(_ value: String) -> Data? {
        guard let data = Data(base64Encoded: value, options: []), data.base64EncodedString() == value else { return nil }
        return data
    }

    private static func isBase64URL32(_ value: String) -> Bool {
        guard value.utf8.count == 43 else { return false }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: base64, options: []) else { return false }
        let canonical = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return data.count == 32 && canonical == value
    }

    private static func isBasename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        if value == "." { return true }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isPairingEndpoint(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && isLoopbackHost(host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if ["localhost", "::1", "[::1]"].contains(host) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, let first = UInt8(octets[0]), first == 127 else { return false }
        return octets.dropFirst().allSatisfy { UInt8($0) != nil }
    }

    private static func isHostname(_ value: String) -> Bool {
        guard value.utf8.count <= 253 else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63 else { return false }
            return label.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$", options: .regularExpression) != nil
        }
    }

    private static func isHarnessBranch(_ value: String) -> Bool {
        guard value.hasPrefix("codex/"),
              value.rangeOfCharacter(from: CharacterSet(charactersIn: " ~^:?*[\\\\]").union(.controlCharacters)) == nil,
              !value.contains(".."), !value.contains("@{"), !value.contains("//"), !value.hasSuffix("/"), !value.hasSuffix(".") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
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
