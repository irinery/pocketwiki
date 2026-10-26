import Foundation

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
}

actor PocketMemoryStore {
    let directory: URL
    private let fileManager = FileManager.default
    private static let eventNames: Set<String> = ["session-start", "user-prompt-submit", "assistant-response", "stop", "session-end"]
    private static let stopwords: Set<String> = ["como", "com", "para", "pelo", "pela", "que", "qual", "quais", "uma", "uns", "das", "dos", "the", "and", "for", "this"]

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func readNote() throws -> String {
        let url = directory.appendingPathComponent("MEMORY.md")
        if !fileManager.fileExists(atPath: url.path) { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writeNote(_ content: String) throws {
        guard content.utf8.count <= 16 * 1024 else { throw PocketMemoryStoreError.invalidInput }
        try write(Data(content.utf8), to: directory.appendingPathComponent("MEMORY.md"))
    }

    func capture(_ events: [PocketMemoryIncomingEvent]) throws -> [String] {
        guard (1...32).contains(events.count) else { throw PocketMemoryStoreError.invalidInput }
        for item in events {
            guard Self.eventNames.contains(item.event), UUID(uuidString: item.sessionID) != nil,
                  item.ingestKey.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                  (item.prompt?.count ?? 0) <= 8_000, (item.message?.count ?? 0) <= 8_000 else {
                throw PocketMemoryStoreError.invalidInput
            }
            if item.event == "user-prompt-submit" && (item.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PocketMemoryStoreError.invalidInput }
            if item.event == "assistant-response" && (item.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PocketMemoryStoreError.invalidInput }
        }

        let captureDirectory = directory.appendingPathComponent("captures", isDirectory: true)
        let now = ISO8601DateFormatter().string(from: Date())
        var records: [String: [String: Any]] = [:]
        var accepted: [String] = []
        for item in events {
            let id = item.sessionID.lowercased()
            let url = captureDirectory.appendingPathComponent("session-\(id).json")
            var record = try records[id] ?? readObject(url) ?? [
                "schema_version": 1, "id": id, "created_at": now, "updated_at": now,
                "messages": [], "events": []
            ]
            guard record["id"] as? String == id,
                  var savedEvents = record["events"] as? [[String: Any]],
                  var messages = record["messages"] as? [[String: Any]] else { throw PocketMemoryStoreError.invalidRecord }
            if savedEvents.contains(where: { $0["ingest_key"] as? String == item.ingestKey }) {
                accepted.append(item.ingestKey)
                records[id] = record
                continue
            }
            guard savedEvents.count < 5_000 else { throw PocketMemoryStoreError.invalidRecord }
            var stored: [String: Any] = [
                "event": item.event, "session_id": id, "ingest_key": item.ingestKey, "created_at": now,
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
        return accepted
    }

    func recall(_ question: String) throws -> PocketMemoryRecallResponse {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.count <= 2_000 else { throw PocketMemoryStoreError.invalidInput }
        var blocks: [String] = []
        var remaining = 5_000
        let note = try readNote().trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            let block = String("Fonte: MEMORY.md\n\(note)".prefix(min(3_000, remaining)))
            blocks.append(block)
            remaining -= block.count
        }
        let terms = Set(Self.words(question).filter { !Self.stopwords.contains($0) })
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
                      let id = record["id"] as? String, UUID(uuidString: id) != nil,
                      let messages = record["messages"] as? [[String: Any]] else { continue }
                let recent = Array(messages.suffix(500))
                var bestScore = 0
                var bestIndex = -1
                for (index, item) in recent.enumerated() {
                    guard let content = item["content"] as? String else { continue }
                    let contentWords = Set(Self.words(content))
                    let score = terms.intersection(contentWords).count
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
        let selected = candidates.values.sorted { $0.score == $1.score ? $0.updated > $1.updated : $0.score > $1.score }.prefix(3)
        var hits: [PocketMemoryHit] = []
        for item in selected where remaining > 0 {
            let block = String("Fonte: \(item.source)/session-\(item.id).json\n\(item.excerpt)".prefix(remaining))
            blocks.append(block)
            remaining -= block.count
            hits.append(PocketMemoryHit(source: item.source, id: item.id, score: item.score))
        }
        return PocketMemoryRecallResponse(context: blocks.joined(separator: "\n\n---\n\n"), hits: hits)
    }

    private func readObject(_ url: URL) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
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
}
