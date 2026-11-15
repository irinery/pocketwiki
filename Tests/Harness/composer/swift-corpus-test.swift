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
        print("Swift corpus: \(cases.count) passed")
    }
}
