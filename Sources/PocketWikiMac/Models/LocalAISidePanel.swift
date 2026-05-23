import Foundation

enum LocalAISidePanel: String, Sendable {
    case llm
    case context

    var title: String {
        switch self {
        case .llm:
            "LM Studio"
        case .context:
            "Contexto"
        }
    }

    var systemImage: String {
        switch self {
        case .llm:
            "server.rack"
        case .context:
            "doc.text"
        }
    }
}
