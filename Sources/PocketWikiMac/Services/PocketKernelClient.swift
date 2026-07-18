import Foundation

enum PocketKernelClientError: Error, LocalizedError {
    case invalidEndpoint
    case badStatus(Int, String?)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Endpoint PocketKernel invalido."
        case .badStatus(let status, let detail):
            if let detail, !detail.isEmpty {
                return "PocketKernel respondeu HTTP \(status): \(detail)"
            }
            return "PocketKernel respondeu HTTP \(status)."
        case .emptyResponse:
            return "PocketKernel respondeu sem conteudo."
        }
    }
}

enum PocketKernelEndpointPolicy {
    static let defaultBaseURL = PocketWikiServerConfiguration.defaultPocketKernelBaseURL

    static func kernelURL(_ rawValue: String) throws -> URL {
        let value = rawValue.pocketTrimmed.isEmpty ? defaultBaseURL : rawValue.pocketTrimmed
        guard let rawURL = URL(string: value),
              LocalAIEndpointPolicy.isAllowedLocalBaseURL(rawURL),
              var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
            throw PocketKernelClientError.invalidEndpoint
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/v1/kernel"
        } else if path == "v1/kernel" || path == "api/kernel/query" {
            components.path = "/" + path
        } else {
            components.path = "/" + [path, "v1/kernel"].joined(separator: "/")
        }

        guard let url = components.url else {
            throw PocketKernelClientError.invalidEndpoint
        }
        return url
    }
}

struct PocketKernelResponse: Sendable {
    let content: String
    let profileUsed: String?
    let missingEvidence: [String]
    let rawSummary: String

    var governanceSummary: String {
        var lines = ["PocketKernel"]
        if let profileUsed, !profileUsed.isEmpty {
            lines.append("profile_used: \(profileUsed)")
        }
        if !missingEvidence.isEmpty {
            lines.append("missing_evidence: \(missingEvidence.joined(separator: ", "))")
        } else {
            lines.append("missing_evidence: []")
        }
        if !rawSummary.isEmpty {
            lines.append(rawSummary)
        }
        return lines.joined(separator: "\n")
    }
}

struct PocketKernelClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func query(
        baseURL: String,
        text: String,
        channel: String = "api",
        appID: String = "pocketwiki",
        userID: String = "local"
    ) async throws -> PocketKernelResponse {
        var request = URLRequest(url: try PocketKernelEndpointPolicy.kernelURL(baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(KernelRequest(
            text: text,
            channel: channel,
            appID: appID,
            userID: userID
        ))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw PocketKernelClientError.badStatus(http.statusCode, Self.errorDetail(from: data))
        }
        return try Self.parseResponse(data)
    }

    static func parseResponse(_ data: Data) throws -> PocketKernelResponse {
        guard !data.isEmpty else { throw PocketKernelClientError.emptyResponse }

        let object = try JSONSerialization.jsonObject(with: data)
        let content = firstString(
            in: object,
            paths: [
                ["answer", "summary"],
                ["data", "answer", "summary"],
                ["result", "answer", "summary"],
                ["answer"],
                ["response"],
                ["text"],
                ["content"],
                ["message"],
                ["output"],
                ["result", "answer"],
                ["result", "response"],
                ["result", "text"],
                ["result", "content"],
                ["data", "answer"],
                ["data", "text"],
                ["choices", 0, "message", "content"]
            ]
        )
        let profileUsed = firstString(
            in: object,
            paths: [
                ["profile_used"],
                ["profileUsed"],
                ["result", "profile_used"],
                ["result", "profileUsed"]
            ]
        )
        let missingEvidence = firstStringArray(
            in: object,
            paths: [
                ["missing_evidence"],
                ["missingEvidence"],
                ["result", "missing_evidence"],
                ["result", "missingEvidence"]
            ]
        )
        let rawSummary = summary(from: object, excluding: ["answer", "response", "text", "content", "message", "output"])
        let fallbackContent = prettyJSON(object)
        let finalContent = content.pocketTrimmed.isEmpty ? fallbackContent : content
        guard !finalContent.pocketTrimmed.isEmpty else { throw PocketKernelClientError.emptyResponse }

        return PocketKernelResponse(
            content: finalContent,
            profileUsed: profileUsed,
            missingEvidence: missingEvidence,
            rawSummary: rawSummary
        )
    }

    private static func firstString(in object: Any, paths: [[AnyHashable]]) -> String {
        for path in paths {
            let value = value(at: path, in: object)
            if let text = stringValue(value), !text.pocketTrimmed.isEmpty {
                return text.pocketTrimmed
            }
        }
        return ""
    }

    private static func firstStringArray(in object: Any, paths: [[AnyHashable]]) -> [String] {
        for path in paths {
            if let values = value(at: path, in: object) as? [Any] {
                let strings = values.compactMap(stringValue).map(\.pocketTrimmed).filter { !$0.isEmpty }
                if !strings.isEmpty { return strings }
            }
        }
        return []
    }

    private static func value(at path: [AnyHashable], in object: Any) -> Any? {
        var current: Any? = object
        for key in path {
            if let string = key as? String {
                current = (current as? [String: Any])?[string]
            } else if let index = key as? Int {
                let array = current as? [Any]
                current = array?.indices.contains(index) == true ? array?[index] : nil
            }
        }
        return current
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case let value as [String: Any]:
            return stringValue(value["content"] ?? value["text"] ?? value["message"])
        case let value as [Any]:
            return value.compactMap(stringValue).joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func summary(from object: Any, excluding excluded: Set<String>) -> String {
        guard let dict = object as? [String: Any] else { return "" }
        let pairs = dict
            .filter { !excluded.contains($0.key) }
            .compactMap { key, value -> String? in
                if let string = stringValue(value), !string.pocketTrimmed.isEmpty {
                    return "\(key): \(string.pocketTrimmed.pocketTruncated(to: 240))"
                }
                return nil
            }
            .prefix(6)
        return pairs.joined(separator: "\n")
    }

    private static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private static func errorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
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
}

private struct KernelRequest: Encodable {
    let text: String
    let channel: String
    let appID: String
    let userID: String

    enum CodingKeys: String, CodingKey {
        case text
        case channel
        case appID = "app_id"
        case userID = "user_id"
    }
}
