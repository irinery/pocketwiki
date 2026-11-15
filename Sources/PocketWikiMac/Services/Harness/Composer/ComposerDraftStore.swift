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
        value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
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

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(referenceID: String, kind: Kind, relativePath: String?, messageID: String?, sha256: String, sizeBytes: Int, trust: Trust) {
        self.referenceID = referenceID
        self.kind = kind
        self.relativePath = relativePath
        self.messageID = messageID
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.trust = trust
    }

    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        let allowed = Set(["reference_id", "kind", "relative_path", "message_id", "sha256", "size_bytes", "trust"])
        guard all.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw ComposerStoreError.invalidReference }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.relativePath), try values.decodeNil(forKey: .relativePath) { throw ComposerStoreError.invalidReference }
        if values.contains(.messageID), try values.decodeNil(forKey: .messageID) { throw ComposerStoreError.invalidReference }
        referenceID = try values.decode(String.self, forKey: .referenceID)
        kind = try values.decode(Kind.self, forKey: .kind)
        relativePath = try values.decodeIfPresent(String.self, forKey: .relativePath)
        messageID = try values.decodeIfPresent(String.self, forKey: .messageID)
        sha256 = try values.decode(String.self, forKey: .sha256)
        sizeBytes = try values.decode(Int.self, forKey: .sizeBytes)
        trust = try values.decode(Trust.self, forKey: .trust)
    }

    func validate() throws {
        guard ComposerIdentity.isCanonicalUUID(referenceID),
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (0...4 * 1024 * 1024).contains(sizeBytes), trust == .untrustedContent else {
            throw ComposerStoreError.invalidReference
        }
        if let relativePath {
            let bytes = Data(relativePath.utf8)
            guard !bytes.isEmpty, bytes.count <= 4096, !relativePath.hasPrefix("/"), !relativePath.contains("\\"), !relativePath.contains("\0"),
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

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(draftID: String, threadID: String, text: String, references: [ComposerContextReference], revision: Int) {
        self.draftID = draftID
        self.threadID = threadID
        self.text = text
        self.references = references
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        let allowed = Set(["draft_id", "thread_id", "text", "references", "revision"])
        guard all.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw ComposerStoreError.invalidDraft }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        draftID = try values.decode(String.self, forKey: .draftID)
        threadID = try values.decode(String.self, forKey: .threadID)
        text = try values.decode(String.self, forKey: .text)
        references = try values.decode([ComposerContextReference].self, forKey: .references)
        revision = try values.decode(Int.self, forKey: .revision)
    }

    func validate(for identity: ComposerIdentity) throws {
        guard ComposerIdentity.isCanonicalUUID(draftID), threadID == identity.threadID,
              Data(text.utf8).count <= 32_768, (0...9_007_199_254_740_991).contains(revision),
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
        guard draft.revision == expectedRevision, expectedRevision < 9_007_199_254_740_991 else { throw ComposerStoreError.revisionConflict }
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
