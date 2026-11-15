import Foundation
import CryptoKit
import SQLite3

struct PocketMemoryIncomingEvent: Codable, Sendable {
    let event: String
    let sessionID: String
    let ingestKey: String
    let prompt: String?
    let message: String?
    let providerID: String?
    let modelID: String?

    enum CodingKeys: String, CodingKey {
        case event, prompt, message
        case sessionID = "session_id"
        case ingestKey = "ingest_key"
        case providerID = "provider_id"
        case modelID = "model_id"
    }
}

struct PocketMemoryCaptureRequest: Codable, Sendable {
    let events: [PocketMemoryIncomingEvent]
}

struct PocketMemoryRecallRequest: Codable, Sendable {
    let question: String
}

struct PocketMemoryNoteRequest: Codable, Sendable {
    let content: String
}

struct PocketMemoryHit: Codable, Sendable {
    let source: String
    let id: String
    let score: Int
}

struct PocketMemoryRecallResponse: Codable, Sendable {
    let context: String
    let hits: [PocketMemoryHit]
}

enum PocketMemoryStoreError: Error {
    case invalidInput
    case invalidRecord
    case forbidden
    case scopeDenied
    case revisionConflict(Int)
    case importInvalid
    case unavailable
    case cursorExpired
}

struct PocketMemoryNamespace: Hashable, Codable, Sendable {
    let environmentID: String
    let projectID: String?
    let threadID: String?
    let schemaVersion: Int
    let noteRevision: Int

    init(environmentID: String, projectID: String?, threadID: String?, schemaVersion: Int = 2, noteRevision: Int = 0) {
        self.environmentID = environmentID; self.projectID = projectID; self.threadID = threadID
        self.schemaVersion = schemaVersion; self.noteRevision = noteRevision
    }

    enum CodingKeys: String, CodingKey {
        case environmentID = "environment_id"
        case projectID = "project_id"
        case threadID = "thread_id"
        case schemaVersion = "schema_version"
        case noteRevision = "note_revision"
    }

    func validated() throws -> PocketMemoryNamespace {
        guard Self.isCanonicalUUID(environmentID),
              projectID.map(Self.isCanonicalUUID) ?? true,
              threadID.map(Self.isCanonicalUUID) ?? true,
              projectID != nil || threadID != nil, schemaVersion == 2, noteRevision >= 0 else { throw PocketMemoryStoreError.invalidInput }
        return PocketMemoryNamespace(environmentID: environmentID, projectID: projectID, threadID: threadID)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

struct PocketMemoryAuthorization: Sendable {
    let principalID: String
    let environmentID: String
    let aggregateID: String?
    let threadID: String?
    let scopes: Set<String>
}

struct PocketMemoryNoteSnapshot: Codable, Sendable, Equatable {
    let content: String
    let revision: Int
}

struct PocketMemoryCaptureResponse: Codable, Sendable, Equatable {
    let acceptedKeys: [String]
    enum CodingKeys: String, CodingKey { case acceptedKeys = "accepted_keys" }
}

struct PocketMemoryMappingResponse: Codable, Sendable, Equatable {
    let mapped: Bool
    let sessionID: String
    enum CodingKeys: String, CodingKey { case mapped, sessionID = "session_id" }
}

struct PocketMemoryExportResponse: Codable, Sendable {
    let content: String
    let sha256: String
}

struct PocketMemoryImportResponse: Codable, Sendable {
    let importedCount: Int
    enum CodingKeys: String, CodingKey { case importedCount = "imported_count" }
}

struct PocketMemoryScopedHit: Codable, Sendable, Equatable {
    let sessionID: String
    let messageID: String
    let source: String
    let snippet: String
    let sha256: String
    let environmentID: String
    let projectID: String?
    let trust: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", messageID = "message_id", source, snippet, sha256
        case environmentID = "environment_id", projectID = "project_id", trust
    }
}

struct PocketMemoryScopedRecallResponse: Codable, Sendable {
    let context: String
    let hits: [PocketMemoryScopedHit]
    let noteRevision: Int
    enum CodingKeys: String, CodingKey { case context, hits, noteRevision = "note_revision" }
}

struct PocketMemorySnapshotItem: Codable, Sendable, Equatable {
    let namespace: PocketMemoryNamespace
    let content: String
    let revision: Int
}

struct PocketMemoryFeatureSnapshot: Codable, Sendable {
    let snapshotID: String
    let revision: Int
    let asOfSeq: Int
    let notes: [PocketMemorySnapshotItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id", revision, asOfSeq = "as_of_seq", notes, nextCursor = "next_cursor"
    }
}

struct PocketMemoryEventProjection: Codable, Sendable, Equatable {
    let eventID: String
    let sequence: Int
    let entityType: String
    let entityKey: String
    let change: String
    let value: PocketMemorySnapshotItem

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", sequence, entityType = "entity_type", entityKey = "entity_key", change, value
    }
}

struct PocketMemorySnapshotScope: Codable {
    let environmentID: String
    let projectID: String?
    let threadID: String?

    init(_ namespace: PocketMemoryNamespace) {
        environmentID = namespace.environmentID; projectID = namespace.projectID; threadID = namespace.threadID
    }

    var namespace: PocketMemoryNamespace {
        PocketMemoryNamespace(environmentID: environmentID, projectID: projectID, threadID: threadID)
    }

    enum CodingKeys: String, CodingKey {
        case environmentID = "environment_id", projectID = "project_id", threadID = "thread_id"
    }
}

struct PocketMemorySnapshotEnvelope: Codable {
    let snapshotID: String
    let principalID: String
    let namespace: PocketMemorySnapshotScope
    let revision: Int
    let asOfSeq: Int
    let expiresAtMS: Int64
    let pageSize: Int
    let items: [PocketMemorySnapshotItem]
    var cursors: [String: Int]

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case principalID = "principal_id"
        case namespace, revision, items, cursors
        case asOfSeq = "as_of_seq"
        case expiresAtMS = "expires_at_ms"
        case pageSize = "page_size"
    }
}

actor PocketMemoryStore {
    let directory: URL
    private let fileManager = FileManager.default
    private static let eventNames: Set<String> = ["session-start", "user-prompt-submit", "assistant-response", "stop", "session-end"]
    private static let stopwords: Set<String> = ["como", "com", "para", "pelo", "pela", "que", "qual", "quais", "uma", "uns", "das", "dos", "the", "and", "for", "this"]

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func scopedStore(_ rawNamespace: PocketMemoryNamespace) throws -> PocketMemoryStore {
        let namespace = try rawNamespace.validated()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try ensureRealDirectory(directory)
        var current = directory
        let kind = namespace.projectID == nil ? "threads" : "projects"
        let identity = namespace.projectID ?? namespace.threadID!
        for component in ["v2", namespace.environmentID, kind, identity] {
            current.appendPathComponent(component, isDirectory: true)
            if fileManager.fileExists(atPath: current.path) {
                try ensureRealDirectory(current)
            } else {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
        }
        return PocketMemoryStore(directory: current)
    }

    func noteGetCAS(namespace: PocketMemoryNamespace? = nil) throws -> PocketMemoryNoteSnapshot {
        if let namespace {
            let state = try readObject(directory.appendingPathComponent(".memory-notes.json")) ?? [:]
            let notes = state["notes"] as? [String: [String: Any]] ?? [:]
            let note = notes[try noteKey(namespace)]
            return PocketMemoryNoteSnapshot(content: note?["content"] as? String ?? "", revision: note?["revision"] as? Int ?? 0)
        }
        let stateURL = directory.appendingPathComponent(".memory-note.json")
        if let state = try readObject(stateURL),
           let content = state["content"] as? String,
           let revision = state["revision"] as? Int, revision >= 0 {
            return PocketMemoryNoteSnapshot(content: content, revision: revision)
        }
        return PocketMemoryNoteSnapshot(content: try readNote(), revision: 0)
    }

    func notePutCAS(_ content: String, expectedRevision: Int, namespace: PocketMemoryNamespace? = nil) throws -> PocketMemoryNoteSnapshot {
        guard content.utf8.count <= 16 * 1024, expectedRevision >= 0 else { throw PocketMemoryStoreError.invalidInput }
        return try withHarnessLock {
        try recoverNoteIntent()
        try recoverImportIntent()
        let current = try noteGetCAS(namespace: namespace)
        guard current.revision == expectedRevision else { throw PocketMemoryStoreError.revisionConflict(current.revision) }
        let next = PocketMemoryNoteSnapshot(content: content, revision: current.revision + 1)
        if let namespace {
            let file = directory.appendingPathComponent(".memory-notes.json")
            var state = try readObject(file) ?? ["sequence": 0, "notes": [String: Any](), "events": [[String: Any]]()]
            var notes = state["notes"] as? [String: Any] ?? [:]
            var events = state["events"] as? [[String: Any]] ?? []
            let key = try noteKey(namespace)
            var ns: [String: Any] = ["environment_id": namespace.environmentID, "schema_version": 2, "note_revision": next.revision]
            if let project = namespace.projectID { ns["project_id"] = project }
            if let thread = namespace.threadID { ns["thread_id"] = thread }
            let value: [String: Any] = ["namespace": ns, "content": content, "revision": next.revision]
            notes[key] = value
            let sequence = (state["sequence"] as? Int ?? 0) + 1
            events.append(["event_id": UUID().uuidString.lowercased(), "sequence": sequence,
                           "entity_type": "MemoryNote", "entity_key": key, "change": "upsert", "value": value])
            state["sequence"] = sequence; state["notes"] = notes; state["events"] = events
            let encoded = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            guard encoded.count <= 16 * 1024 * 1024 else { throw PocketMemoryStoreError.unavailable }
            var target: [String: Any] = ["environment_id": namespace.environmentID]
            if let project = namespace.projectID { target["project_id"] = project }
            if let thread = namespace.threadID { target["thread_id"] = thread }
            let intent: [String: Any] = ["state": state, "namespace": target, "content": content]
            try write(JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys]),
                      to: directory.appendingPathComponent(".note-intent.json"))
            try recoverNoteIntent()
            return next
        }
        let state: [String: Any] = ["schema_version": 2, "content": content, "revision": next.revision]
        try write(JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), to: directory.appendingPathComponent(".memory-note.json"))
        try write(Data(content.utf8), to: directory.appendingPathComponent("MEMORY.md"))
        return next
        }
    }

    private func recoverNoteIntent() throws {
        let intentURL = directory.appendingPathComponent(".note-intent.json")
        guard let intent = try readObject(intentURL, maxBytes: 32 * 1024 * 1024) else { return }
        guard let target = intent["namespace"] as? [String: Any],
              let environment = target["environment_id"] as? String,
              let content = intent["content"] as? String, content.utf8.count <= 16 * 1024,
              let state = intent["state"] as? [String: Any], let sequence = state["sequence"] as? Int, sequence > 0,
              state["events"] is [Any], let notes = state["notes"] as? [String: [String: Any]] else { throw PocketMemoryStoreError.invalidRecord }
        let namespace = try PocketMemoryNamespace(environmentID: environment, projectID: target["project_id"] as? String,
                                                  threadID: target["thread_id"] as? String).validated()
        guard let value = notes[try noteKey(namespace)], value["content"] as? String == content,
              let revision = value["revision"] as? Int, revision > 0 else { throw PocketMemoryStoreError.invalidRecord }
        let encoded = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        guard encoded.count <= 16 * 1024 * 1024 else { throw PocketMemoryStoreError.unavailable }
        let notesDir = directory.appendingPathComponent(".notes", isDirectory: true)
        try ensureRealDirectory(notesDir)
        let noteDir = notesDir.appendingPathComponent(namespace.threadID ?? "project", isDirectory: true)
        try ensureRealDirectory(noteDir)
        try write(Data(content.utf8), to: noteDir.appendingPathComponent("MEMORY.md"))
        try write(encoded, to: directory.appendingPathComponent(".memory-notes.json"))
        try fileManager.removeItem(at: intentURL)
    }

    func scopedNoteGet(namespace: PocketMemoryNamespace) throws -> PocketMemoryNoteSnapshot {
        try withHarnessLock {
            try recoverNoteIntent()
            try recoverImportIntent()
            return try noteGetCAS(namespace: namespace)
        }
    }

    private func noteKey(_ namespace: PocketMemoryNamespace) throws -> String {
        let tuple: [Any] = [namespace.environmentID, namespace.projectID as Any? ?? NSNull(), namespace.threadID as Any? ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: tuple, options: [.fragmentsAllowed])
        guard let text = String(data: data, encoding: .utf8) else { throw PocketMemoryStoreError.invalidRecord }
        return text
    }

    func captureScoped(_ events: [PocketMemoryIncomingEvent]) throws -> [String] {
        try withHarnessLock {
            try recoverNoteIntent()
            try recoverCaptureIntent()
            try recoverImportIntent()
            guard (1...32).contains(events.count) else { throw PocketMemoryStoreError.invalidInput }
            let ledgerURL = directory.appendingPathComponent(".memory-receipts.json")
            var ledger = try readObject(ledgerURL) ?? ["sequence": 0, "accepted_keys": [String: Int]()]
            var sequence = ledger["sequence"] as? Int ?? 0
            var keys = ledger["accepted_keys"] as? [String: Int] ?? [:]
            var prepared: [[String: Any]] = []
            for event in events {
                guard let id = UUID(uuidString: event.sessionID)?.uuidString.lowercased(), id == event.sessionID,
                      Self.eventNames.contains(event.event),
                      event.ingestKey.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                      (event.prompt?.unicodeScalars.count ?? 0) <= 8_000, (event.message?.unicodeScalars.count ?? 0) <= 8_000,
                      (event.providerID?.unicodeScalars.count ?? 0) <= 120, (event.modelID?.unicodeScalars.count ?? 0) <= 120,
                      event.event == "user-prompt-submit" || event.prompt == nil,
                      event.event == "assistant-response" || event.message == nil else {
                    throw PocketMemoryStoreError.invalidInput
                }
                if event.event == "user-prompt-submit" && (event.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PocketMemoryStoreError.invalidInput }
                if event.event == "assistant-response" && (event.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PocketMemoryStoreError.invalidInput }
                let key = "\(id):\(event.ingestKey)"
                if keys[key] == nil { sequence += 1; keys[key] = sequence }
                var item: [String: Any] = ["event": event.event, "session_id": id, "ingest_key": event.ingestKey,
                    "sequence": keys[key]!, "provider_id": event.providerID as Any? ?? NSNull(), "model_id": event.modelID as Any? ?? NSNull()]
                if let prompt = event.prompt { item["prompt"] = prompt }
                if let message = event.message { item["message"] = message }
                prepared.append(item)
            }
            ledger["sequence"] = sequence; ledger["accepted_keys"] = keys
            let intent: [String: Any] = ["events": prepared, "ledger": ledger]
            try write(JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys]),
                      to: directory.appendingPathComponent(".capture-intent.json"))
            try recoverCaptureIntent()
            return events.map(\.ingestKey)
        }
    }

    func recoverCapture() throws {
        try withHarnessLock { try recoverNoteIntent(); try recoverCaptureIntent(); try recoverImportIntent() }
    }

    private func recoverImportIntent() throws {
        let intentURL = directory.appendingPathComponent(".import-intent.json")
        guard let intent = try readObject(intentURL, maxBytes: 32 * 1024 * 1024) else { return }
        guard let records = intent["records"] as? [[String: Any]], records.count <= 500 else { throw PocketMemoryStoreError.invalidRecord }
        let captures = directory.appendingPathComponent("captures", isDirectory: true)
        try ensureRealDirectory(captures)
        var seen = Set<String>()
        for record in records {
            guard let id = record["id"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id,
                  record["messages"] is [Any], record["events"] is [Any], seen.insert(id).inserted else {
                throw PocketMemoryStoreError.invalidRecord
            }
            let target = captures.appendingPathComponent("session-\(id).json")
            if let existing = try readObject(target) {
                guard NSDictionary(dictionary: existing).isEqual(to: record) else { throw PocketMemoryStoreError.revisionConflict(0) }
            } else {
                try write(JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), to: target)
            }
        }
        if let note = intent["note_intent"] as? [String: Any] {
            try write(JSONSerialization.data(withJSONObject: note, options: [.sortedKeys]),
                      to: directory.appendingPathComponent(".note-intent.json"))
            try recoverNoteIntent()
        }
        try fileManager.removeItem(at: intentURL)
    }

    private func recoverCaptureIntent() throws {
        let intentURL = directory.appendingPathComponent(".capture-intent.json")
        guard let intent = try readObject(intentURL) else { return }
        guard let items = intent["events"] as? [[String: Any]], (1...32).contains(items.count),
              let ledger = intent["ledger"] as? [String: Any], let sequence = ledger["sequence"] as? Int, sequence >= 0,
              let keys = ledger["accepted_keys"] as? [String: Int] else { throw PocketMemoryStoreError.invalidRecord }
        var events: [PocketMemoryIncomingEvent] = []
        for item in items {
            guard let id = item["session_id"] as? String, let key = item["ingest_key"] as? String,
                  let itemSequence = item["sequence"] as? Int, itemSequence > 0, itemSequence <= sequence,
                  keys["\(id):\(key)"] == itemSequence else { throw PocketMemoryStoreError.invalidRecord }
            let data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            events.append(try JSONDecoder().decode(PocketMemoryIncomingEvent.self, from: data))
        }
        _ = try capture(events)
        try write(JSONSerialization.data(withJSONObject: ledger, options: [.sortedKeys]),
                  to: directory.appendingPathComponent(".memory-receipts.json"))
        try fileManager.removeItem(at: intentURL)
    }

    private func withHarnessLock<T>(_ body: () throws -> T) throws -> T {
        try ensureRealDirectory(directory)
        let file = directory.appendingPathComponent(".harness-writer.sqlite3")
        guard !isSymbolicLink(file) else { throw PocketMemoryStoreError.scopeDenied }
        if !fileManager.fileExists(atPath: file.path) {
            do { try Data().write(to: file, options: .withoutOverwriting) }
            catch { if !fileManager.fileExists(atPath: file.path) { throw error } }
        }
        guard !isSymbolicLink(file),
              try fileManager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
            throw PocketMemoryStoreError.scopeDenied
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw PocketMemoryStoreError.unavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw PocketMemoryStoreError.unavailable }
        do {
            let result = try body()
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw PocketMemoryStoreError.unavailable }
            return result
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func mapLegacySession(_ sessionID: String, sourceRoot: URL) throws -> Bool {
        try withHarnessLock {
            try recoverCaptureIntent()
            try recoverImportIntent()
            return try mapLegacySessionUnlocked(sessionID, sourceRoot: sourceRoot)
        }
    }

    func exportNamespace(_ namespace: PocketMemoryNamespace, includePersonalNote: Bool) throws -> PocketMemoryExportResponse {
        try withHarnessLock {
            try recoverNoteIntent(); try recoverCaptureIntent(); try recoverImportIntent()
            var scope: [String: Any] = ["environment_id": namespace.environmentID]
            if let project = namespace.projectID { scope["project_id"] = project }
            if let thread = namespace.threadID { scope["thread_id"] = thread }
            let captures = directory.appendingPathComponent("captures", isDirectory: true)
            var sessions: [[String: Any]] = []
            if fileManager.fileExists(atPath: captures.path) {
                try ensureRealDirectory(captures)
                let files = try fileManager.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.range(of: #"^session-[0-9a-f-]{36}\.json$"#, options: .regularExpression) != nil }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for file in files {
                    guard let record = try? readObject(file), let id = record["id"] as? String,
                          UUID(uuidString: id)?.uuidString.lowercased() == id else { continue }
                    let messages = (record["messages"] as? [[String: Any]] ?? []).compactMap { item -> [String: Any]? in
                        guard let role = item["role"] as? String, ["user", "assistant"].contains(role),
                              let content = item["content"] as? String else { return nil }
                        var safe: [String: Any] = ["role": role, "content": Self.redactExportText(content)]
                        if let created = item["created_at"] as? String, Self.isExportTimestamp(created) { safe["created_at"] = created }
                        return safe
                    }
                    let events = (record["events"] as? [[String: Any]] ?? []).compactMap { item -> [String: Any]? in
                        guard let event = item["event"] as? String, Self.eventNames.contains(event),
                              let key = item["ingest_key"] as? String,
                              key.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
                        let safeKey = SHA256.hash(data: Data("memory-export\u{0}\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
                        var safe: [String: Any] = ["event": event, "session_id": id, "ingest_key": safeKey]
                        if let prompt = item["prompt"] as? String { safe["prompt"] = Self.redactExportText(prompt) }
                        if let message = item["message"] as? String { safe["message"] = Self.redactExportText(message) }
                        if let sequence = item["sequence"] as? Int { safe["sequence"] = sequence }
                        return safe
                    }
                    var safe: [String: Any] = ["schema_version": 1, "id": id, "messages": messages, "events": events]
                    if let created = record["created_at"] as? String, Self.isExportTimestamp(created) { safe["created_at"] = created }
                    if let updated = record["updated_at"] as? String, Self.isExportTimestamp(updated) { safe["updated_at"] = updated }
                    sessions.append(safe)
                }
            }
            var exported: [String: Any] = ["schema_version": 2, "namespace": scope, "sessions": sessions]
            if includePersonalNote {
                let note = try noteGetCAS(namespace: namespace)
                exported["note"] = ["content": Self.redactExportText(note.content), "revision": note.revision]
            }
            let bytes = try JSONSerialization.data(withJSONObject: exported, options: [.sortedKeys])
            guard bytes.count <= 16 * 1024 * 1024, let content = String(data: bytes, encoding: .utf8) else { throw PocketMemoryStoreError.invalidInput }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return PocketMemoryExportResponse(content: content, sha256: hash)
        }
    }

    private static func redactExportText(_ input: String) -> String {
        let rules: [(String, String)] = [
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*"#, "[redacted credential]"),
            (#"(?i)\b((?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|senha|token)\s*[:=]\s*)[^\s,;]+"#, "$1[redacted secret]"),
            (#"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{30,})\b"#, "[redacted secret]"),
            (#"(^|[\s(\"'=])(?:/(?!/)[^\s\"'<>]+|[A-Za-z]:\\[^\s\"'<>]+)"#, "$1[redacted path]")
        ]
        return rules.reduce(input) { text, rule in
            text.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
    }

    private static func isExportTimestamp(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$"#, options: .regularExpression) != nil
    }

    func importNamespace(_ namespace: PocketMemoryNamespace, content: String) throws -> PocketMemoryImportResponse {
        guard content.utf8.count <= 16 * 1024 * 1024,
              let data = content.data(using: .utf8),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              document["schema_version"] as? Int == 2,
              let scope = document["namespace"] as? [String: Any],
              scope["environment_id"] as? String == namespace.environmentID,
              scope["project_id"] as? String == namespace.projectID,
              scope["thread_id"] as? String == namespace.threadID,
              let sessions = document["sessions"] as? [[String: Any]], sessions.count <= 500 else {
            throw PocketMemoryStoreError.importInvalid
        }
        let note = document["note"] as? [String: Any]
        if document["note"] != nil {
            guard let note, let text = note["content"] as? String, text.utf8.count <= 16 * 1024,
                  let revision = note["revision"] as? Int, revision >= 0 else { throw PocketMemoryStoreError.importInvalid }
        }
        var records: [[String: Any]] = [], seen = Set<String>()
        for session in sessions {
            guard let id = session["id"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id,
                  seen.insert(id).inserted, let messages = session["messages"] as? [[String: Any]], messages.count <= 5_000,
                  messages.allSatisfy({ item in
                      guard let role = item["role"] as? String, ["user", "assistant"].contains(role),
                            let text = item["content"] as? String else { return false }
                      return text.utf8.count <= 8_000
                  }) else { throw PocketMemoryStoreError.importInvalid }
            if session["events"] != nil && !(session["events"] is [[String: Any]]) { throw PocketMemoryStoreError.importInvalid }
            let events = session["events"] as? [[String: Any]] ?? []
            guard events.count <= 5_000, events.allSatisfy({ item in
                guard let name = item["event"] as? String, Self.eventNames.contains(name),
                      item["session_id"] as? String == id, let key = item["ingest_key"] as? String else { return false }
                let allowed = Set(["event", "session_id", "ingest_key", "prompt", "message", "provider_id", "model_id", "sequence"])
                guard Set(item.keys).isSubset(of: allowed),
                      key.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                      ["prompt", "message", "provider_id", "model_id"].allSatisfy({ item[$0] == nil || item[$0] is String }),
                      item["sequence"] == nil || ((item["sequence"] as? Int ?? 0) > 0),
                      name == "user-prompt-submit" || item["prompt"] == nil,
                      name == "assistant-response" || item["message"] == nil,
                      (item["prompt"] as? String)?.unicodeScalars.count ?? 0 <= 8_000,
                      (item["message"] as? String)?.unicodeScalars.count ?? 0 <= 8_000,
                      (item["provider_id"] as? String)?.unicodeScalars.count ?? 0 <= 120,
                      (item["model_id"] as? String)?.unicodeScalars.count ?? 0 <= 120 else { return false }
                if name == "user-prompt-submit" && (item["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                if name == "assistant-response" && (item["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                return true
            }) else { throw PocketMemoryStoreError.importInvalid }
            records.append(["schema_version": 1, "id": id,
                "created_at": session["created_at"] as? String ?? "1970-01-01T00:00:00.000Z",
                "updated_at": session["updated_at"] as? String ?? "1970-01-01T00:00:00.000Z",
                "messages": messages, "events": events])
        }
        let recordsData = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        let noteContent = note?["content"] as? String
        return try withHarnessLock {
            guard let records = try JSONSerialization.jsonObject(with: recordsData) as? [[String: Any]] else {
                throw PocketMemoryStoreError.importInvalid
            }
            try recoverNoteIntent(); try recoverCaptureIntent(); try recoverImportIntent()
            let captures = directory.appendingPathComponent("captures", isDirectory: true)
            try ensureRealDirectory(captures)
            for record in records {
                let target = captures.appendingPathComponent("session-\(record["id"] as! String).json")
                if isSymbolicLink(target) || fileManager.fileExists(atPath: target.path) { throw PocketMemoryStoreError.revisionConflict(0) }
            }
            var intent: [String: Any] = ["records": records]
            if let content = noteContent {
                let current = try noteGetCAS(namespace: namespace)
                guard current.revision == 0 else { throw PocketMemoryStoreError.revisionConflict(current.revision) }
                let file = directory.appendingPathComponent(".memory-notes.json")
                var state = try readObject(file) ?? ["sequence": 0, "notes": [String: Any](), "events": [[String: Any]]()]
                var notes = state["notes"] as? [String: Any] ?? [:]
                var events = state["events"] as? [[String: Any]] ?? []
                let key = try noteKey(namespace)
                var target: [String: Any] = ["environment_id": namespace.environmentID]
                if let project = namespace.projectID { target["project_id"] = project }
                if let thread = namespace.threadID { target["thread_id"] = thread }
                var valueScope = target; valueScope["schema_version"] = 2; valueScope["note_revision"] = 1
                let value: [String: Any] = ["namespace": valueScope, "content": content, "revision": 1]
                notes[key] = value
                let sequence = (state["sequence"] as? Int ?? 0) + 1
                events.append(["event_id": UUID().uuidString.lowercased(), "sequence": sequence,
                               "entity_type": "MemoryNote", "entity_key": key, "change": "upsert", "value": value])
                state["sequence"] = sequence; state["notes"] = notes; state["events"] = events
                intent["note_intent"] = ["state": state, "namespace": target, "content": content]
            }
            let encoded = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
            guard encoded.count <= 32 * 1024 * 1024 else { throw PocketMemoryStoreError.importInvalid }
            try write(encoded, to: directory.appendingPathComponent(".import-intent.json"))
            try recoverImportIntent()
            return PocketMemoryImportResponse(importedCount: records.count)
        }
    }

    private func mapLegacySessionUnlocked(_ sessionID: String, sourceRoot: URL) throws -> Bool {
        guard UUID(uuidString: sessionID)?.uuidString.lowercased() == sessionID else { throw PocketMemoryStoreError.invalidInput }
        let markerDirectory = directory.appendingPathComponent(".legacy-mappings", isDirectory: true)
        let marker = markerDirectory.appendingPathComponent("\(sessionID).json")
        let target = directory.appendingPathComponent("captures/session-\(sessionID).json")
        if try readObject(marker) != nil, try readObject(target) != nil { return true }
        let candidates = [
            sourceRoot.appendingPathComponent("session-\(sessionID).json"),
            sourceRoot.appendingPathComponent("captures/session-\(sessionID).json")
        ]
        guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let attributes = try? fileManager.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 16 * 1024 * 1024,
              let record = try readObject(source),
              (record["id"] as? String)?.lowercased() == sessionID,
              let messages = record["messages"] as? [[String: Any]] else { throw PocketMemoryStoreError.importInvalid }
        let safeMessages = messages.compactMap { item -> [String: Any]? in
            guard let role = item["role"] as? String, ["user", "assistant"].contains(role),
                  let content = item["content"] as? String else { return nil }
            return ["role": role, "content": content, "created_at": item["created_at"] ?? record["updated_at"] ?? record["created_at"] ?? "1970-01-01T00:00:00.000Z"]
        }
        let imported: [String: Any] = [
            "schema_version": 1, "id": sessionID,
            "created_at": record["created_at"] ?? "1970-01-01T00:00:00.000Z",
            "updated_at": record["updated_at"] ?? "1970-01-01T00:00:00.000Z",
            "messages": safeMessages, "events": record["events"] ?? []
        ]
        if let existing = try readObject(target) {
            guard NSDictionary(dictionary: existing).isEqual(to: imported) else { throw PocketMemoryStoreError.revisionConflict(0) }
        } else {
            try write(JSONSerialization.data(withJSONObject: imported, options: [.prettyPrinted, .sortedKeys]), to: target)
        }
        let mapping: [String: Any] = ["schema_version": 1, "session_id": sessionID, "source": "legacy-v1"]
        try write(JSONSerialization.data(withJSONObject: mapping, options: [.sortedKeys]), to: marker)
        return true
    }

    func snapshotProjection(namespace: PocketMemoryNamespace) throws -> (items: [PocketMemorySnapshotItem], sequence: Int) {
        try withHarnessLock {
            try recoverNoteIntent()
            try recoverImportIntent()
            let state = try readObject(directory.appendingPathComponent(".memory-notes.json")) ?? [:]
            let notes = state["notes"] as? [String: [String: Any]] ?? [:]
            var items: [PocketMemorySnapshotItem] = []
            for key in notes.keys.sorted() {
                guard let value = notes[key] else { continue }
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                let note = try JSONDecoder().decode(PocketMemorySnapshotItem.self, from: data)
                if let thread = namespace.threadID, note.namespace.threadID != thread { continue }
                items.append(note)
            }
            return (items, state["sequence"] as? Int ?? 0)
        }
    }

    func eventsSince(_ afterSequence: Int, namespace: PocketMemoryNamespace) throws -> [PocketMemoryEventProjection] {
        guard afterSequence >= 0 else { throw PocketMemoryStoreError.invalidInput }
        return try withHarnessLock {
        try recoverNoteIntent()
        try recoverImportIntent()
        let state = try readObject(directory.appendingPathComponent(".memory-notes.json")) ?? [:]
        let entries = state["events"] as? [[String: Any]] ?? []
        return try entries.compactMap { entry in
            guard let sequence = entry["sequence"] as? Int, sequence > afterSequence else { return nil }
            let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            let event = try JSONDecoder().decode(PocketMemoryEventProjection.self, from: data)
            if let thread = namespace.threadID, event.value.namespace.threadID != thread { return nil }
            return event
        }
        }
    }

    func notesRetentionAvailable(after sequence: Int) throws -> Bool {
        try withHarnessLock {
        try recoverNoteIntent()
        try recoverImportIntent()
        guard let state = try readObject(directory.appendingPathComponent(".memory-notes.json")) else { return sequence == 0 }
        guard let current = state["sequence"] as? Int, current >= sequence,
              let events = state["events"] as? [[String: Any]] else { return false }
        let later = events.compactMap { $0["sequence"] as? Int }.filter { $0 > sequence }
        return later.count == current - sequence && later.enumerated().allSatisfy { $0.element == sequence + $0.offset + 1 }
        }
    }

    func recallScoped(_ question: String, namespace: PocketMemoryNamespace, includePersonalNote: Bool) throws -> PocketMemoryScopedRecallResponse {
        try withHarnessLock {
            try recoverNoteIntent()
            try recoverCaptureIntent()
            try recoverImportIntent()
            return try recallScopedUnlocked(question, namespace: namespace, includePersonalNote: includePersonalNote)
        }
    }

    private func recallScopedUnlocked(_ question: String, namespace: PocketMemoryNamespace, includePersonalNote: Bool) throws -> PocketMemoryScopedRecallResponse {
        let personalNote = includePersonalNote ? try noteGetCAS(namespace: namespace) : nil
        let result = try recall(question, includeNote: false, harnessScoring: true,
                                limit: (personalNote?.content.isEmpty == false) ? 2 : 3)
        let terms = Self.harnessWords(question)
        var hits: [PocketMemoryScopedHit] = []
        for hit in result.hits {
            guard let record = try readObject(directory.appendingPathComponent("captures/session-\(hit.id).json")),
                  let messages = record["messages"] as? [[String: Any]] else { continue }
            let recent = Array(messages.suffix(500)).filter { item in
                guard let role = item["role"] as? String else { return false }
                return ["user", "assistant"].contains(role) && item["content"] is String
            }
            var bestScore = 0, bestIndex = -1
            for (index, item) in recent.enumerated() {
                let normalized = Self.harnessNormalize(item["content"] as! String)
                let score = terms.filter { normalized.contains($0) }.count
                if score > 0 && score >= bestScore { bestScore = score; bestIndex = index }
            }
            guard bestIndex >= 0 else { continue }
            let nearby = recent[max(0, bestIndex - 1)..<min(recent.count, bestIndex + 2)]
            let text = nearby.map { "[\($0["role"] as! String)] \($0["content"] as! String)" }.joined(separator: "\n\n")
            let snippet = Self.utf8Prefix(String(String.UnicodeScalarView(text.unicodeScalars.prefix(2_200))), limit: 4_096)
            let sha = SHA256.hash(data: Data(snippet.utf8)).map { String(format: "%02x", $0) }.joined()
            let messageID = Self.deterministicUUID("\(hit.id)\u{0}\(snippet)")
            hits.append(PocketMemoryScopedHit(sessionID: hit.id, messageID: messageID, source: "history", snippet: snippet,
                sha256: sha, environmentID: namespace.environmentID, projectID: namespace.projectID, trust: "historical"))
        }
        var context = result.context
        var revision = 0
        if includePersonalNote {
            let note = personalNote!
            revision = note.revision
            let content = note.content
            if !content.isEmpty {
                let snippet = Self.utf8Prefix(String(String.UnicodeScalarView(content.unicodeScalars.prefix(3_000))), limit: 4_096)
                let sha = SHA256.hash(data: Data(snippet.utf8)).map { String(format: "%02x", $0) }.joined()
                let scopeID = namespace.projectID ?? namespace.threadID ?? ""
                hits.insert(PocketMemoryScopedHit(
                    sessionID: Self.deterministicUUID("note\u{0}\(namespace.environmentID)\u{0}\(scopeID)"),
                    messageID: Self.deterministicUUID("note\u{0}\(revision)\u{0}\(snippet)"), source: "note",
                    snippet: snippet, sha256: sha, environmentID: namespace.environmentID,
                    projectID: namespace.projectID, trust: "historical"), at: 0)
                context = String(("Fonte: MEMORY.md\n\(snippet)\n\n---\n\n" + context).prefix(5_000))
            }
        }
        return PocketMemoryScopedRecallResponse(context: String(context.prefix(5_000)), hits: hits, noteRevision: revision)
    }

    func readNote() throws -> String {
        let url = directory.appendingPathComponent("MEMORY.md")
        guard !isSymbolicLink(url) else { throw PocketMemoryStoreError.scopeDenied }
        if !fileManager.fileExists(atPath: url.path) { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writeNote(_ content: String) throws {
        guard content.utf8.count <= 16 * 1024 else { throw PocketMemoryStoreError.invalidInput }
        try write(Data(content.utf8), to: directory.appendingPathComponent("MEMORY.md"))
    }

    func capture(_ events: [PocketMemoryIncomingEvent]) throws -> [String] {
        guard (1...32).contains(events.count) else { throw PocketMemoryStoreError.invalidInput }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ensureRealDirectory(directory)
        let captureDirectory = directory.appendingPathComponent("captures", isDirectory: true)
        try ensureRealDirectory(captureDirectory)
        for item in events {
            guard Self.eventNames.contains(item.event), UUID(uuidString: item.sessionID) != nil,
                  item.ingestKey.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                  (item.prompt?.count ?? 0) <= 8_000, (item.message?.count ?? 0) <= 8_000 else {
                throw PocketMemoryStoreError.invalidInput
            }
            if item.event == "user-prompt-submit" && (item.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PocketMemoryStoreError.invalidInput }
            if item.event == "assistant-response" && (item.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PocketMemoryStoreError.invalidInput }
        }

        let now = ISO8601DateFormatter().string(from: Date())
        var records: [String: [String: Any]] = [:]
        var accepted: [String] = []
        let receiptURL = directory.appendingPathComponent(".memory-receipts.json")
        var receipt = try readObject(receiptURL) ?? ["sequence": 0, "accepted_keys": [String: Int]()]
        var sequence = receipt["sequence"] as? Int ?? 0
        var acceptedKeys = receipt["accepted_keys"] as? [String: Int] ?? [:]
        for item in events {
            let id = item.sessionID.lowercased()
            let receiptKey = "\(id):\(item.ingestKey)"
            let assignedSequence: Int
            if let saved = acceptedKeys[receiptKey] {
                assignedSequence = saved
            } else {
                sequence += 1
                assignedSequence = sequence
                acceptedKeys[receiptKey] = assignedSequence
            }
            let url = captureDirectory.appendingPathComponent("session-\(id).json")
            var record = try records[id] ?? readObject(url) ?? [
                "schema_version": 1, "id": id, "created_at": now, "updated_at": now,
                "messages": [], "events": []
            ]
            guard record["id"] as? String == id,
                  var savedEvents = record["events"] as? [[String: Any]],
                  var messages = record["messages"] as? [[String: Any]] else { throw PocketMemoryStoreError.invalidRecord }
            if let existingIndex = savedEvents.firstIndex(where: { $0["ingest_key"] as? String == item.ingestKey }) {
                if savedEvents[existingIndex]["sequence"] == nil {
                    savedEvents[existingIndex]["sequence"] = assignedSequence
                    record["events"] = savedEvents
                    record["updated_at"] = now
                }
                accepted.append(item.ingestKey)
                records[id] = record
                continue
            }
            guard savedEvents.count < 5_000 else { throw PocketMemoryStoreError.invalidRecord }
            var stored: [String: Any] = [
                "event": item.event, "session_id": id, "ingest_key": item.ingestKey, "created_at": now,
                "sequence": assignedSequence,
                "provider_id": item.providerID.map { String($0.prefix(120)) } ?? NSNull(),
                "model_id": item.modelID.map { String($0.prefix(120)) } ?? NSNull()
            ]
            if let prompt = item.prompt { stored["prompt"] = prompt }
            if let message = item.message { stored["message"] = message }
            savedEvents.append(stored)
            let content = item.event == "user-prompt-submit" ? item.prompt : item.event == "assistant-response" ? item.message : nil
            if let content {
                messages.append([
                    "role": item.event == "user-prompt-submit" ? "user" : "assistant",
                    "content": content, "created_at": now,
                    "provider_id": item.providerID.map { String($0.prefix(120)) } ?? NSNull(),
                    "model_id": item.modelID.map { String($0.prefix(120)) } ?? NSNull()
                ])
            }
            record["events"] = savedEvents
            record["messages"] = messages
            record["updated_at"] = now
            records[id] = record
            accepted.append(item.ingestKey)
        }
        for (id, record) in records {
            let url = captureDirectory.appendingPathComponent("session-\(id).json")
            try write(JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), to: url)
        }
        receipt["sequence"] = sequence
        receipt["accepted_keys"] = acceptedKeys
        try write(JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), to: receiptURL)
        return accepted
    }

    func recall(_ question: String, includeNote: Bool = true, harnessScoring: Bool = false, limit: Int = 3) throws -> PocketMemoryRecallResponse {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.count <= 2_000 else { throw PocketMemoryStoreError.invalidInput }
        var blocks: [String] = []
        var remaining = 5_000
        let note = includeNote ? try readNote().trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !note.isEmpty {
            let block = String("Fonte: MEMORY.md\n\(note)".prefix(min(3_000, remaining)))
            blocks.append(block)
            remaining -= block.count
        }
        let terms = Set(harnessScoring ? Self.harnessWords(question) : Self.words(question).filter { !Self.stopwords.contains($0) })
        struct Candidate {
            let source: String
            let id: String
            let score: Int
            let excerpt: String
            let updated: String
        }
        var files: [(url: URL, source: String, modified: Date)] = []
        for (folder, source) in [(directory, "local"), (directory.appendingPathComponent("captures"), "captured")] {
            let entries = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])) ?? []
            for url in entries where url.lastPathComponent.range(of: #"^session-[0-9a-fA-F-]{36}\.json$"#, options: .regularExpression) != nil {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) <= 16 * 1024 * 1024 else { continue }
                files.append((url, source, values.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.modified > $1.modified }
        var candidates: [String: Candidate] = [:]
        for file in files.prefix(500) {
                guard let record = try? readObject(file.url),
                      let rawID = record["id"] as? String, UUID(uuidString: rawID) != nil,
                      let messages = record["messages"] as? [[String: Any]] else { continue }
                let id = rawID.lowercased()
                let recent = Array(messages.suffix(500))
                var bestScore = 0
                var bestIndex = -1
                for (index, item) in recent.enumerated() {
                    guard let content = item["content"] as? String else { continue }
                    let score: Int
                    if harnessScoring {
                        let normalized = Self.harnessNormalize(content)
                        score = terms.filter { normalized.contains($0) }.count
                    } else {
                        score = terms.intersection(Set(Self.words(content))).count
                    }
                    if score >= bestScore && score > 0 { bestScore = score; bestIndex = index }
                }
                guard bestIndex >= 0 else { continue }
                let nearby = recent[max(0, bestIndex - 1)..<min(recent.count, bestIndex + 2)]
                let excerpt = String(nearby.compactMap { item -> String? in
                    guard let role = item["role"] as? String,
                          let content = item["content"] as? String,
                          ["user", "assistant"].contains(role) else { return nil }
                    return "[\(role)] \(content)"
                }.joined(separator: "\n\n").prefix(2_200))
                let candidate = Candidate(source: file.source, id: id, score: bestScore, excerpt: excerpt,
                    updated: record["updated_at"] as? String ?? "")
                if let previous = candidates[id], previous.score > bestScore || (previous.score == bestScore && file.source != "local") { continue }
                candidates[id] = candidate
        }
        let selected = candidates.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.updated != $1.updated { return $0.updated > $1.updated }
            return $0.id < $1.id
        }.prefix(limit)
        var hits: [PocketMemoryHit] = []
        for item in selected where remaining > 0 {
            let block = String("Fonte: \(item.source)/session-\(item.id).json\n\(item.excerpt)".prefix(remaining))
            blocks.append(block)
            remaining -= block.count
            hits.append(PocketMemoryHit(source: item.source, id: item.id, score: item.score))
        }
        return PocketMemoryRecallResponse(context: blocks.joined(separator: "\n\n---\n\n"), hits: hits)
    }

    private func readObject(_ url: URL, maxBytes: Int = 16 * 1024 * 1024) throws -> [String: Any]? {
        guard !isSymbolicLink(url) else { throw PocketMemoryStoreError.scopeDenied }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maxBytes else {
            throw PocketMemoryStoreError.invalidRecord
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    }

    private func ensureRealDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        guard !isSymbolicLink(url),
              try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw PocketMemoryStoreError.scopeDenied
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func words(_ text: String) -> [String] {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
    }

    private static func harnessNormalize(_ text: String) -> String {
        text.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
            .map(String.init).joined().lowercased()
    }

    private static func utf8Prefix(_ text: String, limit: Int) -> String {
        var result = "", bytes = 0
        for scalar in text.unicodeScalars {
            let next = String(scalar)
            let size = next.utf8.count
            if bytes + size > limit { break }
            result.append(next); bytes += size
        }
        return result
    }

    private static func harnessWords(_ text: String) -> [String] {
        let normalized = harnessNormalize(text)
        let regex = try! NSRegularExpression(pattern: "[a-z0-9]{3,}")
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex.matches(in: normalized, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: normalized) else { return nil }
            return String(normalized[range])
        }.filter { !stopwords.contains($0) }
        return Array(Set(matches))
    }

    private static func deterministicUUID(_ value: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}
