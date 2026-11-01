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
}
