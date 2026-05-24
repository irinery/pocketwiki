import Foundation

enum LocalAIChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

struct LocalAIChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: LocalAIChatRole
    var content: String
    var reasoning: String
    var finishReason: String?
    var usageSummary: String?
    var modelID: String?
    let createdAt: Date
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: LocalAIChatRole,
        content: String,
        reasoning: String = "",
        finishReason: String? = nil,
        usageSummary: String? = nil,
        modelID: String? = nil,
        createdAt: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.usageSummary = usageSummary
        self.modelID = modelID
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }
}

enum LocalAIContextScope: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case currentPage
    case linkedPages
    case wikiDigest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            "Auto"
        case .currentPage:
            "Pagina"
        case .linkedPages:
            "Links"
        case .wikiDigest:
            "Wiki"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic:
            "scope"
        case .currentPage:
            "doc.text"
        case .linkedPages:
            "link"
        case .wikiDigest:
            "square.grid.2x2"
        }
    }
}

enum LocalAIContextMode: String, Hashable, Sendable {
    case general
    case wiki
}

struct LocalAIContextPayload: Hashable, Sendable {
    let mode: LocalAIContextMode
    let title: String
    let body: String
    let includedPaths: [String]
    let manualPaths: [String]
    let characters: Int
    let notice: String?
}

struct LocalAIManualContextSource: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let path: String
    let content: String
    let characters: Int

    init(id: UUID = UUID(), title: String, path: String, content: String) {
        self.id = id
        self.title = title
        self.path = path
        self.content = content
        self.characters = content.count
    }
}

struct LocalAIModel: Identifiable, Hashable, Sendable {
    let id: String
    let ownedBy: String?
    let object: String?
    let type: String?
    let task: String?
    let kind: String?

    init(
        id: String,
        ownedBy: String? = nil,
        object: String? = nil,
        type: String? = nil,
        task: String? = nil,
        kind: String? = nil
    ) {
        self.id = id
        self.ownedBy = ownedBy
        self.object = object
        self.type = type
        self.task = task
        self.kind = kind
    }

    var isChatCandidate: Bool {
        let folded = id.lowercased()
        let owner = (ownedBy ?? "").lowercased()
        let metadata = [object, type, task, kind]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return !folded.contains("embed")
            && !folded.contains("embedding")
            && !folded.contains("rerank")
            && !owner.contains("embedding")
            && !metadata.contains("embedding")
            && !metadata.contains("embed")
    }
}

struct LocalAIStreamDelta: Sendable {
    var content = ""
    var reasoning = ""
    var finishReason: String?
    var usageSummary: String?
    var modelID: String?
}
