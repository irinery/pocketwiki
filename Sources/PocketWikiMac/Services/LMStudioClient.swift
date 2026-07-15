import Foundation

/// Compatibility namespace for decoding OpenAI-compatible LM Studio payloads.
/// Network access is intentionally handled by MiddlewareAuth/PocketKernel.
enum LMStudioClient {
    static func parseModelsResponse(_ data: Data) throws -> [LocalAIModel] {
        let object = try JSONSerialization.jsonObject(with: data)
        let rawModels: [Any]

        if let models = object as? [Any] {
            rawModels = models
        } else if let root = object as? [String: Any], let models = root["data"] as? [Any] {
            rawModels = models
        } else if let root = object as? [String: Any], let models = root["models"] as? [Any] {
            rawModels = models
        } else {
            rawModels = []
        }

        return rawModels.compactMap { item in
            if let id = item as? String {
                let model = LocalAIModel(id: id.pocketTrimmed)
                return model.id.isEmpty || !model.isChatCandidate ? nil : model
            }

            guard let values = item as? [String: Any] else { return nil }
            let id = stringValue(values["id"])
                ?? stringValue(values["name"])
                ?? stringValue(values["model"])
                ?? ""
            let model = LocalAIModel(
                id: id.pocketTrimmed,
                ownedBy: stringValue(values["owned_by"]),
                object: stringValue(values["object"]),
                type: stringValue(values["type"]),
                task: stringValue(values["task"]),
                kind: stringValue(values["kind"])
            )
            return model.id.isEmpty || !model.isChatCandidate ? nil : model
        }
    }

    static func parseChatCompletionResponse(_ data: Data) throws -> LocalAIStreamDelta {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw LMStudioPayloadError.invalidObject
        }

        var result = LocalAIStreamDelta()
        let choices = root["choices"] as? [[String: Any]] ?? []

        for choice in choices {
            let message = choice["delta"] as? [String: Any]
                ?? choice["message"] as? [String: Any]
            result.content += stringValue(message?["content"])
                ?? stringValue(choice["text"])
                ?? ""
            result.reasoning += stringValue(message?["reasoning_content"])
                ?? stringValue(message?["reasoning"])
                ?? stringValue(choice["reasoning_content"])
                ?? stringValue(choice["reasoning"])
                ?? ""
            result.finishReason = stringValue(choice["finish_reason"]) ?? result.finishReason
            result.usageSummary = usageSummary(choice["usage"]) ?? result.usageSummary
            result.modelID = stringValue(message?["model"]) ?? result.modelID
        }

        if result.content.isEmpty {
            result.content = stringValue(root["output_text"])
                ?? stringValue(root["text"])
                ?? ""
        }
        if result.reasoning.isEmpty {
            result.reasoning = stringValue(root["reasoning_content"])
                ?? stringValue(root["reasoning"])
                ?? ""
        }
        result.finishReason = stringValue(root["finish_reason"]) ?? result.finishReason
        result.usageSummary = usageSummary(root["usage"]) ?? result.usageSummary
        result.modelID = stringValue(root["model"]) ?? result.modelID
        return result
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            value
        case let value as NSNumber:
            value.stringValue
        default:
            nil
        }
    }

    private static func usageSummary(_ value: Any?) -> String? {
        guard let usage = value as? [String: Any] else { return nil }
        let parts = [
            integerValue(usage["prompt_tokens"]).map { "prompt \($0)" },
            integerValue(usage["completion_tokens"]).map { "resposta \($0)" },
            integerValue(usage["total_tokens"]).map { "total \($0)" }
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}

private enum LMStudioPayloadError: Error {
    case invalidObject
}
