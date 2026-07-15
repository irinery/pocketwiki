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

enum LocalAIProviderMethod: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case lmStudio = "lmstudio"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .lmStudio:
            "LM Studio"
        }
    }

    var systemImage: String {
        switch self {
        case .openAI:
            "sparkles"
        case .lmStudio:
            "point.3.connected.trianglepath.dotted"
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .openAI:
            "Login"
        case .lmStudio:
            "Configurar"
        }
    }

    var statusFallback: String {
        switch self {
        case .openAI:
            "Faça login para conectar sua conta OpenAI."
        case .lmStudio:
            "Configure o LM Studio no MiddlewareAuth."
        }
    }

    static func value(for rawValue: String) -> LocalAIProviderMethod {
        LocalAIProviderMethod(rawValue: rawValue) ?? .openAI
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
