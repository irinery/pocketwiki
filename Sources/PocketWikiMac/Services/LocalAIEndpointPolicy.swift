import Foundation

enum LocalAIEndpointPolicyError: Error, LocalizedError, Equatable {
    case invalidURL
    case nonLocalEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Endpoint invalido. Use algo como http://127.0.0.1:1234/v1."
        case .nonLocalEndpoint:
            "Por seguranca, esta fase aceita apenas localhost, .local ou IP de rede privada."
        }
    }
}

enum LocalAIEndpointPolicy {
    static let defaultBaseURL = "http://127.0.0.1:1234/v1"

    static func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let value = rawValue.pocketTrimmed
        guard let url = URL(string: value), isAllowedLocalBaseURL(url) else {
            throw value.isEmpty ? LocalAIEndpointPolicyError.invalidURL : LocalAIEndpointPolicyError.nonLocalEndpoint
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LocalAIEndpointPolicyError.invalidURL
        }
        let cleanPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleanPath.isEmpty {
            components.path = "/v1"
        } else if cleanPath == "api/ai" {
            components.path = "/api/ai"
        } else {
            components.path = "/" + cleanPath
        }
        guard let normalized = components.url else {
            throw LocalAIEndpointPolicyError.invalidURL
        }
        return normalized
    }

    static func endpointURL(baseURL rawValue: String, path: String) throws -> URL {
        let baseURL = try normalizedBaseURL(rawValue)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw LocalAIEndpointPolicyError.invalidURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath == "api/ai", suffix == "chat/completions" {
            suffix = "chat"
        }
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")

        guard let url = components.url else {
            throw LocalAIEndpointPolicyError.invalidURL
        }
        return url
    }

    static func isAllowedLocalBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        return host == "localhost"
            || host.hasSuffix(".local")
            || isAllowedIPv4Host(host)
            || isAllowedIPv6Host(host)
    }

    private static func isAllowedIPv4Host(_ host: String) -> Bool {
        let octets = host.split(separator: ".")
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ 0...255 ~= $0 }) else {
            return false
        }

        let first = values[0]
        let second = values[1]
        return first == 10
            || first == 127
            || first == 169 && second == 254
            || first == 172 && (16...31 ~= second)
            || first == 192 && second == 168
            || first == 100 && (64...127 ~= second)
    }

    private static func isAllowedIPv6Host(_ host: String) -> Bool {
        if host == "::1" {
            return true
        }
        guard let firstSegment = host.split(separator: ":").first,
              let firstHextet = Int(firstSegment, radix: 16) else {
            return false
        }

        return 0xfc00...0xfdff ~= firstHextet
            || 0xfe80...0xfebf ~= firstHextet
    }
}
