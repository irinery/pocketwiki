import Foundation

enum LocalAISidePanel: String, Sendable {
    case llm
    case context

    var title: String {
        switch self {
        case .llm:
            "IA"
        case .context:
            "Contexto"
        }
    }

    var systemImage: String {
        switch self {
        case .llm:
            "sparkles"
        case .context:
            "doc.text"
        }
    }
}

enum LocalAIReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            "Baixo"
        case .medium:
            "Médio"
        case .high:
            "Alto"
        }
    }
}
