import Foundation

enum LMStudioClientError: Error, LocalizedError {
    case missingModel
    case badStatus(Int, String?)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingModel:
            "Informe ou selecione um modelo carregado no LM Studio."
        case .badStatus(let status, let detail):
            if let detail, !detail.isEmpty {
                "LM Studio respondeu HTTP \(status): \(detail)"
            } else {
                "LM Studio respondeu HTTP \(status). Confira servidor, token e modelo carregado."
            }
        case .emptyResponse:
            "O streaming terminou sem conteudo."
        }
    }
}

struct LMStudioClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listModels(baseURL: String, apiKey: String?) async throws -> [LocalAIModel] {
        var request = URLRequest(url: try LocalAIEndpointPolicy.endpointURL(baseURL: baseURL, path: "models"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(apiKey, request: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response, body: data)
        return try Self.parseModelsResponse(data)
    }

    static func parseModelsResponse(_ data: Data) throws -> [LocalAIModel] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data
            .compactMap(\.model)
            .filter(\.isChatCandidate)
    }

    static func parseChatCompletionResponse(_ data: Data) throws -> LocalAIStreamDelta {
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
        var delta = LocalAIStreamDelta()
        for choice in chunk.choices {
            let rawDelta = choice.delta ?? choice.message
            delta.content += rawDelta?.content ?? choice.text ?? ""
            delta.reasoning += rawDelta?.reasoningContent
                ?? rawDelta?.reasoning
                ?? choice.reasoningContent
                ?? choice.reasoning
                ?? ""
            delta.finishReason = choice.finishReason ?? delta.finishReason
            delta.usageSummary = choice.usage?.summary ?? delta.usageSummary
            delta.modelID = rawDelta?.model ?? delta.modelID
        }

        if delta.content.isEmpty {
            delta.content = chunk.outputText ?? chunk.text ?? ""
        }
        if delta.reasoning.isEmpty {
            delta.reasoning = chunk.reasoningContent ?? chunk.reasoning ?? ""
        }
        delta.finishReason = chunk.finishReason ?? delta.finishReason
        delta.usageSummary = chunk.usage?.summary ?? delta.usageSummary
        delta.modelID = chunk.model ?? delta.modelID
        return delta
    }

    func streamChat(
        baseURL: String,
        apiKey: String?,
        modelID: String,
        temperature: Double,
        context: LocalAIContextPayload,
        messages: [LocalAIChatMessage]
    ) throws -> AsyncThrowingStream<LocalAIStreamDelta, Error> {
        let model = modelID.pocketTrimmed
        guard !model.isEmpty else {
            throw LMStudioClientError.missingModel
        }

        let request = try makeChatRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            modelID: model,
            temperature: temperature,
            context: context,
            messages: messages
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedContent = false
                var fallbackBody = ""
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                        throw LMStudioClientError.badStatus(http.statusCode, try await errorDetail(from: bytes))
                    }

                    for try await line in bytes.lines {
                        guard let payload = ssePayload(from: line) else {
                            let clean = line.pocketTrimmed
                            if !clean.isEmpty {
                                fallbackBody += clean
                            }
                            continue
                        }
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        let streamDelta = try Self.parseChatCompletionResponse(data)
                        if !streamDelta.content.isEmpty || !streamDelta.reasoning.isEmpty {
                            emittedContent = true
                            continuation.yield(streamDelta)
                        }
                    }

                    if !emittedContent,
                       let data = fallbackBody.data(using: .utf8),
                       !fallbackBody.isEmpty {
                        let streamDelta = try Self.parseChatCompletionResponse(data)
                        if !streamDelta.content.isEmpty || !streamDelta.reasoning.isEmpty {
                            emittedContent = true
                            continuation.yield(streamDelta)
                        }
                    }

                    if emittedContent {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: LMStudioClientError.emptyResponse)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func makeChatRequest(
        baseURL: String,
        apiKey: String?,
        modelID: String,
        temperature: Double,
        context: LocalAIContextPayload,
        messages: [LocalAIChatMessage]
    ) throws -> URLRequest {
        var request = URLRequest(url: try LocalAIEndpointPolicy.endpointURL(baseURL: baseURL, path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthorization(apiKey, request: &request)

        let question = messages.last(where: { $0.role == .user })?.content ?? ""
        let requestBody = ChatCompletionRequest(
            model: modelID,
            messages: [
                ChatMessage(role: "system", content: LocalAIContextBuilder.systemPrompt(context: context)),
                ChatMessage(role: "user", content: LocalAIContextBuilder.userPrompt(question: question, context: context))
            ],
            temperature: temperature,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(requestBody)
        return request
    }

    private func applyAuthorization(_ apiKey: String?, request: inout URLRequest) {
        let token = apiKey?.pocketTrimmed ?? ""
        guard !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func validate(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard 200..<300 ~= http.statusCode else {
            throw LMStudioClientError.badStatus(http.statusCode, errorDetail(from: body))
        }
    }

    private func ssePayload(from line: String) -> String? {
        let trimmed = line.pocketTrimmed
        guard trimmed.hasPrefix("data:") else { return nil }
        return String(trimmed.dropFirst(5)).pocketTrimmed
    }

    private func errorDetail(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                return (error["message"] as? String ?? error["type"] as? String)?.pocketTrimmed
            }
            if let message = object["message"] as? String {
                return message.pocketTrimmed
            }
            if let error = object["error"] as? String {
                return error.pocketTrimmed
            }
        }
        return String(data: data, encoding: .utf8)?.pocketTruncated(to: 500)
    }

    private func errorDetail(from bytes: URLSession.AsyncBytes) async throws -> String? {
        var body = ""
        for try await line in bytes.lines {
            body += line
            if body.count > 4_096 { break }
        }
        return errorDetail(from: body.data(using: .utf8))
    }
}

private struct ModelsResponse: Decodable {
    let data: [ModelItem]

    init(from decoder: Decoder) throws {
        if let items = try? [ModelItem](from: decoder) {
            data = items
            return
        }

        let container = try decoder.container(keyedBy: ModelCodingKey.self)
        if let items = try? container.decode([ModelItem].self, forKey: ModelCodingKey("data")) {
            data = items
        } else if let items = try? container.decode([ModelItem].self, forKey: ModelCodingKey("models")) {
            data = items
        } else {
            data = []
        }
    }
}

private struct ModelItem: Decodable {
    let id: String
    let ownedBy: String?
    let object: String?
    let type: String?
    let task: String?
    let kind: String?

    var model: LocalAIModel? {
        let cleanID = id.pocketTrimmed
        guard !cleanID.isEmpty else { return nil }
        return LocalAIModel(
            id: cleanID,
            ownedBy: ownedBy,
            object: object,
            type: type,
            task: task,
            kind: kind
        )
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            id = value
            ownedBy = nil
            object = nil
            type = nil
            task = nil
            kind = nil
            return
        }

        let container = try decoder.container(keyedBy: ModelCodingKey.self)
        id = container.stringValue(for: "id")
            ?? container.stringValue(for: "name")
            ?? container.stringValue(for: "model")
            ?? ""
        ownedBy = container.stringValue(for: "owned_by")
        object = container.stringValue(for: "object")
        type = container.stringValue(for: "type")
        task = container.stringValue(for: "task")
        kind = container.stringValue(for: "kind")
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatCompletionChunk: Decodable {
    let model: String?
    let choices: [Choice]
    let usage: Usage?
    let finishReason: String?
    let outputText: String?
    let text: String?
    let reasoning: String?
    let reasoningContent: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
        finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
        outputText = try container.decodeIfPresent(String.self, forKey: .outputText)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
    }

    enum CodingKeys: String, CodingKey {
        case model
        case choices
        case usage
        case finishReason = "finish_reason"
        case outputText = "output_text"
        case text
        case reasoning
        case reasoningContent = "reasoning_content"
    }

    struct Choice: Decodable {
        let delta: Delta?
        let message: Delta?
        let text: String?
        let finishReason: String?
        let usage: Usage?
        let reasoning: String?
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case message
            case text
            case finishReason = "finish_reason"
            case usage
            case reasoning
            case reasoningContent = "reasoning_content"
        }
    }

    struct Delta: Decodable {
        let content: String?
        let reasoning: String?
        let reasoningContent: String?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoning
            case reasoningContent = "reasoning_content"
            case model
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        var summary: String? {
            let parts = [
                promptTokens.map { "prompt \($0)" },
                completionTokens.map { "resposta \($0)" },
                totalTokens.map { "total \($0)" }
            ].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

private struct ModelCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == ModelCodingKey {
    func stringValue(for key: String) -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: ModelCodingKey(key)) else {
            if let number = try? decodeIfPresent(Int.self, forKey: ModelCodingKey(key)) {
                return "\(number)"
            }
            return nil
        }
        return value
    }
}
