import Foundation

@main struct CorpusTest {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/Harness/composer/reference-corpus.json"))
        let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for item in cases {
            let value = try JSONSerialization.data(withJSONObject: item["value"]!)
            var accepted = true
            do { let reference = try JSONDecoder().decode(ComposerContextReference.self, from: value); try reference.validate() }
            catch { accepted = false }
            guard accepted == item["accept"] as! Bool else { fatalError("Corpus mismatch: \(item["id"]!)") }
        }
        let draftData = try Data(contentsOf: URL(fileURLWithPath: "Tests/Harness/composer/draft-corpus.json"))
        let drafts = try JSONSerialization.jsonObject(with: draftData) as! [[String: Any]]
        let identity = ComposerIdentity(principalID: "11111111-1111-4111-8111-111111111111", environmentID: "33333333-3333-4333-8333-333333333333", threadID: "44444444-4444-4444-8444-444444444444")
        for item in drafts {
            let value = try JSONSerialization.data(withJSONObject: item["value"]!)
            var accepted = true
            do { let draft = try JSONDecoder().decode(ComposerDraft.self, from: value); try draft.validate(for: identity) }
            catch { accepted = false }
            guard accepted == item["accept"] as! Bool else { fatalError("Draft corpus mismatch: \(item["id"]!)") }
        }
        print("Swift corpus: \(cases.count + drafts.count) passed")
    }
}
