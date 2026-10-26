import Foundation

struct PortableConversationMessage: Codable, Sendable {
    let role: String
    let content: String
    let createdAt: Date
    let providerID: String?
    let modelID: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case createdAt = "created_at"
        case providerID = "provider_id"
        case modelID = "model_id"
    }
}

struct PortableConversationSession: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var messages: [PortableConversationMessage]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messages
    }
}

/// Stores readable, provider-neutral chat records outside the model/provider runtime.
struct PortableConversationStore {
    private let directory: URL
    let memoryFileURL: URL
    private let hookOutboxURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let memoryDirectory = directoryURL ?? appSupport.appendingPathComponent("PocketWiki/AI Memory", isDirectory: true)
        directory = memoryDirectory
        memoryFileURL = memoryDirectory.appendingPathComponent("MEMORY.md")
        hookOutboxURL = memoryDirectory.appendingPathComponent("ai-memory-outbox.json")
    }

    func restoreOrCreateSession() -> PortableConversationSession {
        try? prepareDirectory()
        createMemoryFileIfNeeded()

        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let newest = sessions
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }

        if let file = newest.first,
           let data = try? Data(contentsOf: file),
           let session = try? decodeSession(data),
           session.schemaVersion == 1 {
            return session
        }
        return newSession()
    }

    func newSession() -> PortableConversationSession {
        let now = Date()
        return PortableConversationSession(schemaVersion: 1, id: UUID(), createdAt: now, updatedAt: now, messages: [])
    }

    func save(_ session: PortableConversationSession, messages: [LocalAIChatMessage]) throws {
        try prepareDirectory()
        var record = session
        record.updatedAt = Date()
        record.messages = messages.compactMap { message in
            guard message.role != .system, !message.content.pocketTrimmed.isEmpty, !message.isStreaming else { return nil }
            return PortableConversationMessage(
                role: message.role.rawValue,
                content: message.content,
                createdAt: message.createdAt,
                providerID: message.providerID,
                modelID: message.modelID
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let destination = sessionURL(id: record.id)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func loadMemory() -> String {
        createMemoryFileIfNeeded()
        return (try? String(contentsOf: memoryFileURL, encoding: .utf8))?.pocketTrimmed ?? ""
    }

    func pendingHooks(for configuration: AIMemoryConfiguration) throws -> [AIMemoryHookEvent] {
        try readHookOutbox().filter {
            $0.endpoint == configuration.endpoint.absoluteString
                && $0.workspace == configuration.workspace
                && $0.project == configuration.project
        }
    }

    func enqueueHooks(_ events: [AIMemoryHookEvent]) throws {
        guard !events.isEmpty else { return }
        var pending = try readHookOutbox()
        var keys = Set(pending.map { "\($0.endpoint)|\($0.workspace)|\($0.project)|\($0.ingestKey)" })
        pending.append(contentsOf: events.filter {
            keys.insert("\($0.endpoint)|\($0.workspace)|\($0.project)|\($0.ingestKey)").inserted
        })
        try writeHookOutbox(pending)
    }

    func acknowledgeHooks(_ keys: Set<String>, for configuration: AIMemoryConfiguration) throws {
        guard !keys.isEmpty else { return }
        try writeHookOutbox(readHookOutbox().filter {
            !($0.endpoint == configuration.endpoint.absoluteString
                && $0.workspace == configuration.workspace
                && $0.project == configuration.project
                && keys.contains($0.ingestKey))
        })
    }

    private func createMemoryFileIfNeeded() {
        guard !FileManager.default.fileExists(atPath: memoryFileURL.path) else { return }
        try? prepareDirectory()
        try? "".write(to: memoryFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: memoryFileURL.path)
    }

    private func sessionURL(id: UUID) -> URL {
        directory.appendingPathComponent("session-\(id.uuidString.lowercased()).json")
    }

    private func readHookOutbox() throws -> [AIMemoryHookEvent] {
        guard FileManager.default.fileExists(atPath: hookOutboxURL.path) else { return [] }
        return try JSONDecoder().decode([AIMemoryHookEvent].self, from: Data(contentsOf: hookOutboxURL))
    }

    private func writeHookOutbox(_ events: [AIMemoryHookEvent]) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(events).write(to: hookOutboxURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hookOutboxURL.path)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func decodeSession(_ data: Data) throws -> PortableConversationSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PortableConversationSession.self, from: data)
    }
}
