import Foundation
import CryptoKit

struct ComposerIdentity: Codable, Equatable, Hashable {
    let principalID: String
    let environmentID: String
    let threadID: String

    var storageKey: String { "\(principalID):\(environmentID):\(threadID)" }

    func validate() throws {
        guard Self.isCanonicalUUID(principalID), Self.isCanonicalUUID(environmentID), Self.isCanonicalUUID(threadID) else {
            throw ComposerStoreError.invalidIdentity
        }
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

struct ComposerContextReference: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case wiki, file, quote, image }
    enum Trust: String, Codable { case untrustedContent = "untrusted_content" }

    let referenceID: String
    let kind: Kind
    let relativePath: String?
    let messageID: String?
    let sha256: String
    let sizeBytes: Int
    let trust: Trust

    var id: String { referenceID }

    enum CodingKeys: String, CodingKey {
        case kind, sha256, trust
        case referenceID = "reference_id"
        case relativePath = "relative_path"
        case messageID = "message_id"
        case sizeBytes = "size_bytes"
    }

    func validate() throws {
        guard ComposerIdentity.isCanonicalUUID(referenceID),
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (0...4 * 1024 * 1024).contains(sizeBytes), trust == .untrustedContent else {
            throw ComposerStoreError.invalidReference
        }
        if let relativePath {
            let bytes = Data(relativePath.utf8)
            guard !bytes.isEmpty, bytes.count <= 4096, !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else {
                throw ComposerStoreError.invalidReference
            }
        }
        if let messageID, !ComposerIdentity.isCanonicalUUID(messageID) {
            throw ComposerStoreError.invalidReference
        }
    }
}

struct ComposerDraft: Codable, Equatable, Identifiable {
    let draftID: String
    let threadID: String
    var text: String
    var references: [ComposerContextReference]
    var revision: Int

    var id: String { draftID }

    enum CodingKeys: String, CodingKey {
        case text, references, revision
        case draftID = "draft_id"
        case threadID = "thread_id"
    }

    func validate(for identity: ComposerIdentity) throws {
        guard ComposerIdentity.isCanonicalUUID(draftID), threadID == identity.threadID,
              Data(text.utf8).count <= 32_768, revision >= 0,
              references.count <= 20 else {
            throw ComposerStoreError.invalidDraft
        }
        var ids = Set<String>()
        for reference in references {
            try reference.validate()
            guard ids.insert(reference.referenceID).inserted else { throw ComposerStoreError.invalidDraft }
        }
    }
}

enum ComposerStoreError: Error, Equatable {
    case invalidIdentity
    case invalidDraft
    case invalidReference
    case revisionConflict
    case notFound
    case persistenceFailure
}

actor ComposerDraftStore {
    private struct StoredDraft: Codable {
        let identityKey: String
        var draft: ComposerDraft
        var expiresAtMS: Int64
    }

    private struct Stash: Codable {
        var schemaVersion = 1
        var drafts: [StoredDraft] = []
    }

    private let directory: URL
    private let fileURL: URL
    private var stash: Stash
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        self.fileURL = self.directory.appendingPathComponent("composer-drafts-v1.json", isDirectory: false)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]

        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let data = try Data(contentsOf: self.fileURL, options: [.mappedIfSafe])
                self.stash = try decoder.decode(Stash.self, from: data)
                guard stash.schemaVersion == 1 else { throw ComposerStoreError.persistenceFailure }
            } else {
                self.stash = Stash()
            }
        } catch let error as ComposerStoreError {
            throw error
        } catch {
            throw ComposerStoreError.persistenceFailure
        }
    }

    @discardableResult
    func save(_ draft: ComposerDraft, for identity: ComposerIdentity, expectedRevision: Int, nowMS: Int64) throws -> Int {
        try identity.validate()
        try draft.validate(for: identity)
        guard draft.revision == expectedRevision else { throw ComposerStoreError.revisionConflict }
        var candidate = stash
        candidate.drafts.removeAll { $0.expiresAtMS <= nowMS }
        let key = identity.storageKey
        let index = candidate.drafts.firstIndex { $0.identityKey == key && $0.draft.draftID == draft.draftID }
        let currentRevision = index.map { candidate.drafts[$0].draft.revision } ?? 0
        guard currentRevision == expectedRevision else { throw ComposerStoreError.revisionConflict }

        var saved = draft
        saved.revision = expectedRevision + 1
        let record = StoredDraft(identityKey: key, draft: saved, expiresAtMS: nowMS + 86_400_000)
        if let index { candidate.drafts[index] = record } else { candidate.drafts.append(record) }
        try persist(candidate)
        stash = candidate
        return saved.revision
    }

    func load(draftID: String, for identity: ComposerIdentity, nowMS: Int64) throws -> ComposerDraft {
        try identity.validate()
        guard let record = stash.drafts.first(where: { $0.identityKey == identity.storageKey && $0.draft.draftID == draftID && $0.expiresAtMS > nowMS }) else {
            throw ComposerStoreError.notFound
        }
        return record.draft
    }

    private func persist(_ candidate: Stash) throws {
        do {
            let data = try encoder.encode(candidate)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw ComposerStoreError.persistenceFailure
        }
    }
}
