import Foundation

@main
struct HarnessV1CorpusRunner {
    static func main() throws {
        let corpusURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let schemaURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [String: Any]
        let schemaDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as! [String: Any]
        let slots = corpus["slots"] as! [[String: Any]]
        var failures = 0

        for slot in slots {
            let id = slot["id"] as! String
            let schema = slot["schema"] as! String
            let expected = slot["accept"] as! Bool
            let value = slot["value"]!
            let operation = slot["operation"] as? String
            let actual = HarnessV1.validateCorpusValue(value, schemaName: schema, document: schemaDocument, operationName: operation)
            if actual != expected {
                failures += 1
                fputs("FAIL \(id): expected \(expected), got \(actual)\n", stderr)
            }
        }

        guard failures == 0 else { throw RunnerError.failed(failures) }
        print("Swift corpus: \(slots.count) slots passed")
    }

    enum RunnerError: Error { case failed(Int) }
}
