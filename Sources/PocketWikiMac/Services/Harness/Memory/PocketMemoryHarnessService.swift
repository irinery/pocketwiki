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
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "memory.write")
        let store = try await store(for: namespace)
        return PocketMemoryCaptureResponse(acceptedKeys: try await store.captureScoped(events))
    }

    func recallScoped(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace,
                      question: String, includePersonalNote: Bool = false) async throws -> PocketMemoryScopedRecallResponse {
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "context.read",
            includePersonalNote ? "memory.personal.read" : nil)
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.unicodeScalars.count <= 2_000 else {
            throw PocketMemoryStoreError.invalidInput
        }
        let store = try await store(for: namespace)
        return try await store.recallScoped(question, namespace: namespace, includePersonalNote: includePersonalNote)
    }

    func noteGet(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace) async throws -> PocketMemoryNoteSnapshot {
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "memory.personal.read")
        return try await store(for: namespace).noteGetCAS(namespace: namespace)
    }

    func notePut(_ auth: PocketMemoryAuthorization, namespace rawNamespace: PocketMemoryNamespace,
                 content: String, expectedRevision: Int) async throws -> PocketMemoryNoteSnapshot {
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "memory.write")
        guard content.utf8.count <= 16 * 1024, expectedRevision >= 0 else { throw PocketMemoryStoreError.invalidInput }
        return try await store(for: namespace).notePutCAS(content, expectedRevision: expectedRevision, namespace: namespace)
    }

    func mapLegacy(_ auth: PocketMemoryAuthorization, legacySessionID: String,
                   namespace rawNamespace: PocketMemoryNamespace) async throws -> Bool {
        let namespace = try await authorize(auth, namespace: rawNamespace, scope: "memory.write")
        guard UUID(uuidString: legacySessionID)?.uuidString.lowercased() == legacySessionID else {
            throw PocketMemoryStoreError.invalidInput
        }
        return try await store(for: namespace).mapLegacySession(legacySessionID, sourceRoot: rootStore.directory)
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
            guard saved.principalID == auth.principalID, saved.namespace == namespace else { throw PocketMemoryStoreError.scopeDenied }
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
                principalID: auth.principalID, namespace: namespace, revision: projection.sequence,
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
        if let store = stores[key] { return store }
        let store = try await rootStore.scopedStore(namespace)
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
