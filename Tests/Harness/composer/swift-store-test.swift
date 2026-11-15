import Foundation

@main struct ComposerStoreTest {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("composer-swift-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("stash")
        let moved = root.appendingPathComponent("moved")
        defer { try? fm.removeItem(at: root) }
        let identity = ComposerIdentity(principalID: "11111111-1111-4111-8111-111111111111", environmentID: "33333333-3333-4333-8333-333333333333", threadID: "44444444-4444-4444-8444-444444444444")
        let draft = ComposerDraft(draftID: "55555555-5555-4555-8555-555555555555", threadID: identity.threadID, text: "draft", references: [], revision: 0)
        let store = try ComposerDraftStore(directory: dir)
        try fm.moveItem(at: dir, to: moved)
        do {
            _ = try await store.save(draft, for: identity, expectedRevision: 0, nowMS: 1000)
            fatalError("save unexpectedly succeeded")
        } catch ComposerStoreError.persistenceFailure {}
        try fm.moveItem(at: moved, to: dir)
        let revision = try await store.save(draft, for: identity, expectedRevision: 0, nowMS: 1000)
        precondition(revision == 1)
        let reopened = try ComposerDraftStore(directory: dir)
        let loaded = try await reopened.load(draftID: draft.draftID, for: identity, nowMS: 1001)
        precondition(loaded.text == "draft" && loaded.revision == 1)
        print("Swift store: 1 passed")
    }
}
