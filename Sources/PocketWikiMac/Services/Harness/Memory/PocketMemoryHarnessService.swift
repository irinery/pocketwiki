import Foundation

actor PocketMemoryHarnessService {
    typealias Policy = @Sendable (PocketMemoryAuthorization, PocketMemoryNamespace, String, Bool) async throws -> Bool
    private let rootStore: PocketMemoryStore
    private var stores: [String: PocketMemoryStore] = [:]
    private let policy: Policy?
    private let now: @Sendable () -> Int64

    init(directory: URL, policy: Policy? = nil, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        rootStore = PocketMemoryStore(directory: directory)
        self.policy = policy
        self.now = now
    }

    func captureScoped(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace,
                       events: [PocketMemoryIncomingEvent]) async throws -> PocketMemoryCaptureResponse {
        guard (1...32).contains(events.count) else { throw PocketMemoryStoreError.invalidInput }
        for event in events {
            guard UUID(uuidString: event.sessionID)?.uuidString.lowercased() == event.sessionID,
                  ["session-start", "user-prompt-submit", "assistant-response", "stop", "session-end"].contains(event.event),
                  event.ingestKey.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                  (event.prompt?.unicodeScalars.count ?? 0) <= 8_000, (event.message?.unicodeScalars.count ?? 0) <= 8_000,
                  (event.providerID?.unicodeScalars.count ?? 0) <= 120, (event.modelID?.unicodeScalars.count ?? 0) <= 120,
                  event.event == "user-prompt-submit" || event.prompt == nil,
                  event.event == "assistant-response" || event.message == nil else { throw PocketMemoryStoreError.invalidInput }
            if event.event == "user-prompt-submit" && (event.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PocketMemoryStoreError.invalidInput }
            if event.event == "assistant-response" && (event.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PocketMemoryStoreError.invalidInput }
        }
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "memory.write")
        let store = try await store(for: namespace)
        return PocketMemoryCaptureResponse(acceptedKeys: try await store.captureScoped(events))
    }

    func recallScoped(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace,
                      question: String, includePersonalNote: Bool = false) async throws -> PocketMemoryScopedRecallResponse {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.unicodeScalars.count <= 2_000 else {
            throw PocketMemoryStoreError.invalidInput
        }
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "context.read",
            includePersonalNote ? "memory.personal.read" : nil)
        let store = try await store(for: namespace)
        return try await store.recallScoped(question, namespace: namespace, includePersonalNote: includePersonalNote)
    }

    func noteGet(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace) async throws -> PocketMemoryNoteSnapshot {
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "memory.personal.read")
        return try await store(for: namespace).scopedNoteGet(namespace: namespace)
    }

    func notePut(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace,
                 content: String, expectedRevision: Int) async throws -> PocketMemoryNoteSnapshot {
        guard content.utf8.count <= 16 * 1024, expectedRevision >= 0 else { throw PocketMemoryStoreError.invalidInput }
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "memory.write")
        return try await store(for: namespace).notePutCAS(content, expectedRevision: expectedRevision, namespace: namespace)
    }

    func mapLegacy(_ auth: PocketMemoryAuthorization, legacySessionID: String,
                   namespace rawNamespace: PocketMemoryNamespace) async throws -> PocketMemoryMappingResponse {
        guard UUID(uuidString: legacySessionID)?.uuidString.lowercased() == legacySessionID else {
            throw PocketMemoryStoreError.invalidInput
        }
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "memory.write")
        let store = try await store(for: namespace)
        var sourceValid = false
        for parent in [rootStore.directory, rootStore.directory.appendingPathComponent("captures", isDirectory: true)] {
            if isSymbolicLink(parent) { throw PocketMemoryStoreError.scopeDenied }
            guard FileManager.default.fileExists(atPath: parent.path) else { continue }
            guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw PocketMemoryStoreError.scopeDenied
            }
            let source = parent.appendingPathComponent("session-\(legacySessionID).json")
            if isSymbolicLink(source) { throw PocketMemoryStoreError.scopeDenied }
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 16 * 1024 * 1024,
                  let data = try? Data(contentsOf: source),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  record["schema_version"] as? Int == 1, record["id"] as? String == legacySessionID,
                  record["messages"] is [Any] else { throw PocketMemoryStoreError.importInvalid }
            sourceValid = true
            break
        }
        guard sourceValid else { throw PocketMemoryStoreError.importInvalid }
        let mappingDirectory = rootStore.directory.appendingPathComponent(".legacy-mappings", isDirectory: true)
        try ensurePrivateDirectory(mappingDirectory)
        let marker = mappingDirectory.appendingPathComponent("\(legacySessionID).json")
        guard !isSymbolicLink(marker) else { throw PocketMemoryStoreError.scopeDenied }
        var target: [String: Any] = ["environment_id": namespace.environmentID]
        if let project = namespace.projectID { target["project_id"] = project }
        if let thread = namespace.threadID { target["thread_id"] = thread }
        let intent: [String: Any] = ["principal_id": auth.principalID, "namespace": target]
        let encoded = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
        do {
            try encoded.write(to: marker, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        } catch {
            guard !isSymbolicLink(marker), let data = try? Data(contentsOf: marker),
                  let prior = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let priorNamespace = prior["namespace"] as? [String: Any],
                  prior["principal_id"] as? String == auth.principalID,
                  priorNamespace["environment_id"] as? String == namespace.environmentID,
                  priorNamespace["project_id"] as? String == namespace.projectID,
                  priorNamespace["thread_id"] as? String == namespace.threadID else {
                throw PocketMemoryStoreError.revisionConflict(0)
            }
        }
        return PocketMemoryMappingResponse(mapped: try await store.mapLegacySession(legacySessionID, sourceRoot: rootStore.directory),
                                           sessionID: legacySessionID)
    }

    func snapshot(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace,
                  pageSize: Int? = nil, cursor: String? = nil) async throws -> PocketMemoryFeatureSnapshot {
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "context.read", "memory.personal.read")
        guard pageSize.map({ (1...100).contains($0) }) ?? true, cursor.map({ $0.range(of: #"^[0-9a-f-]{36}\.[0-9a-f-]{36}$"#, options: .regularExpression) != nil }) ?? true else {
            throw PocketMemoryStoreError.invalidInput
        }
        let store = try await store(for: namespace)
        let snapshotsDirectory = store.directory.appendingPathComponent(".snapshots", isDirectory: true)
        try ensurePrivateDirectory(snapshotsDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        var envelope: PocketMemorySnapshotEnvelope
        var offset = 0
        if let cursor {
            let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw PocketMemoryStoreError.invalidInput }
            let snapshotID = String(parts[0])
            let file = snapshotsDirectory.appendingPathComponent("snapshot-\(snapshotID).json")
            guard !isSymbolicLink(file) else { throw PocketMemoryStoreError.scopeDenied }
            guard let data = try? Data(contentsOf: file), data.count <= 16 * 1024 * 1024 else { throw PocketMemoryStoreError.cursorExpired }
            let saved: PocketMemorySnapshotEnvelope
            do { saved = try decoder.decode(PocketMemorySnapshotEnvelope.self, from: data) }
            catch { throw PocketMemoryStoreError.cursorExpired }
            guard saved.principalID == auth.principalID, saved.namespace.namespace == namespace else { throw PocketMemoryStoreError.scopeDenied }
            guard saved.expiresAtMS > now() else { throw PocketMemoryStoreError.cursorExpired }
            let retained = (try? await store.notesRetentionAvailable(after: saved.asOfSeq)) ?? false
            guard retained else { throw PocketMemoryStoreError.cursorExpired }
            guard pageSize == nil || pageSize == saved.pageSize else { throw PocketMemoryStoreError.invalidInput }
            guard let position = saved.cursors[cursor] else { throw PocketMemoryStoreError.invalidInput }
            envelope = saved
            offset = position
        } else {
            let projection = try await store.snapshotProjection(namespace: namespace)
            let size = pageSize ?? 100
            envelope = PocketMemorySnapshotEnvelope(snapshotID: UUID().uuidString.lowercased(),
                principalID: auth.principalID, namespace: PocketMemorySnapshotScope(namespace), revision: projection.sequence,
                asOfSeq: projection.sequence, expiresAtMS: now() + 600_000, pageSize: size,
                items: projection.items, cursors: [:])
            var position = size
            while position < envelope.items.count {
                envelope.cursors["\(envelope.snapshotID).\(UUID().uuidString.lowercased())"] = position
                position += size
            }
            let file = snapshotsDirectory.appendingPathComponent("snapshot-\(envelope.snapshotID).json")
            try writeAtomically(encoder.encode(envelope), to: file)
        }
        let page = Array(envelope.items.dropFirst(offset).prefix(envelope.pageSize))
        let nextOffset = offset + page.count
        let nextCursor: String?
        if nextOffset < envelope.items.count {
            guard let token = envelope.cursors.first(where: { $0.value == nextOffset })?.key else { throw PocketMemoryStoreError.cursorExpired }
            nextCursor = token
        } else { nextCursor = nil }
        return PocketMemoryFeatureSnapshot(snapshotID: envelope.snapshotID, revision: envelope.revision,
            asOfSeq: envelope.asOfSeq, notes: page, nextCursor: nextCursor)
    }

    func eventsSince(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace,
                     afterSequence: Int) async throws -> [PocketMemoryEventProjection] {
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "context.read", "memory.personal.read")
        return try await store(for: namespace).eventsSince(afterSequence, namespace: namespace)
    }

    private func store(for namespace: PocketMemoryNamespace) async throws -> PocketMemoryStore {
        let key = [namespace.environmentID, namespace.projectID ?? "", namespace.threadID ?? ""].joined(separator: ":")
        if let store = stores[key] {
            try await store.recoverCapture()
            return store
        }
        let store = try await rootStore.scopedStore(namespace)
        try await store.recoverCapture()
        stores[key] = store
        return store
    }

    private func authorize(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace,
                           scope: String, _ additionalScope: String? = nil) async throws -> PocketMemoryNamespace {
        let namespace = try rawNamespace.validated()
        guard UUID(uuidString: auth.principalID)?.uuidString.lowercased() == auth.principalID,
              UUID(uuidString: auth.environmentID)?.uuidString.lowercased() == auth.environmentID,
              auth.environmentID == namespace.environmentID else { throw PocketMemoryStoreError.forbidden }
        guard auth.scopes.contains(scope), additionalScope.map(auth.scopes.contains) ?? true else {
            throw PocketMemoryStoreError.scopeDenied
        }
        if let projectID = namespace.projectID, auth.aggregateID != projectID { throw PocketMemoryStoreError.scopeDenied }
        if let requestedThread = namespace.threadID, auth.threadID != requestedThread {
            throw PocketMemoryStoreError.scopeDenied
        }
        if namespace.threadID == nil && auth.threadID != nil { throw PocketMemoryStoreError.scopeDenied }
        guard let policy else { throw PocketMemoryStoreError.unavailable }
        let granted: Bool
        do { granted = try await policy(auth, namespace, scope, additionalScope != nil || scope == "memory.personal.read") }
        catch { throw PocketMemoryStoreError.unavailable }
        guard granted else { throw PocketMemoryStoreError.forbidden }
        return namespace
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        guard !isSymbolicLink(url),
              try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw PocketMemoryStoreError.scopeDenied
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        guard !isSymbolicLink(url) else { throw PocketMemoryStoreError.scopeDenied }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
