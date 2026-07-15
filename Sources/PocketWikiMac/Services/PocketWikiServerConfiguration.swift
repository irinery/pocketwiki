import Foundation

struct PocketWikiServerConfiguration: Equatable, Sendable {
    var port: Int
    var bindHost: String
    var publicHosts: [String]
    var mdnsEnabled: Bool
    var referencePath: String
    var referenceReadonly: Bool
    var writeToken: String
    var writeMaxBytes: Int
    var lmStudioBaseURL: String
    var lmStudioAPIKey: String
    var lmStudioModel: String
    var pocketKernelBaseURL: String
    var middlewareAuthBaseURL: String
    var middlewareAuthClientToken: String
    var middlewareAuthProjectID: String
    var middlewareAuthProfileID: String
    var envPath: String?

    static let defaultReferencePath = "SKILL/wiki-reference"
    static let minimumWriteRequestBytes = 8 * 1024 * 1024
    static let defaultPocketKernelBaseURL = "http://127.0.0.1:8080"
    static let defaultMiddlewareAuthBaseURL = "http://127.0.0.1:18787"

    static var defaults: PocketWikiServerConfiguration {
        PocketWikiServerConfiguration(
            port: 8787,
            bindHost: "0.0.0.0",
            publicHosts: ["pocketwiki.local", "pokectwiki.local"],
            mdnsEnabled: true,
            referencePath: defaultReferencePath,
            referenceReadonly: true,
            writeToken: "",
            writeMaxBytes: minimumWriteRequestBytes,
            lmStudioBaseURL: LocalAIEndpointPolicy.defaultBaseURL,
            lmStudioAPIKey: "",
            lmStudioModel: "",
            pocketKernelBaseURL: defaultPocketKernelBaseURL,
            middlewareAuthBaseURL: defaultMiddlewareAuthBaseURL,
            middlewareAuthClientToken: "",
            middlewareAuthProjectID: "acme",
            middlewareAuthProfileID: "default",
            envPath: nil
        )
    }

    var routes: PocketWikiRouteSnapshot {
        PocketWikiRouteBuilder.build(port: port, bindHost: bindHost, publicHosts: publicHosts)
    }

    var resolvedReferenceURL: URL {
        URL(fileURLWithPath: Self.resolvePath(referencePath))
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> PocketWikiServerConfiguration {
        let envPath = candidateEnvPaths(environment: environment, bundle: bundle, fileManager: fileManager)
            .first { fileManager.fileExists(atPath: $0.path) }
        let fileValues = envPath.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(parseEnv) ?? [:]

        return PocketWikiServerConfiguration(
            port: Int(value("POCKETWIKI_PORT", environment: environment, fileValues: fileValues, fallback: "8787")) ?? 8787,
            bindHost: value("POCKETWIKI_BIND_HOST", environment: environment, fileValues: fileValues, fallback: "0.0.0.0"),
            publicHosts: PocketWikiRouteBuilder.parsePublicHosts(
                value("POCKETWIKI_PUBLIC_HOSTS", environment: environment, fileValues: fileValues)
                    .ifEmpty(value("POCKETWIKI_PUBLIC_HOST", environment: environment, fileValues: fileValues))
                    .ifEmpty("pocketwiki.local,pokectwiki.local")
            ),
            mdnsEnabled: boolValue("POCKETWIKI_MDNS", environment: environment, fileValues: fileValues, fallback: true),
            referencePath: Self.resolvePath(value("POCKETWIKI_REFERENCE_PATH", environment: environment, fileValues: fileValues, fallback: defaultReferencePath)),
            referenceReadonly: boolValue("POCKETWIKI_REFERENCE_READONLY", environment: environment, fileValues: fileValues, fallback: true),
            writeToken: value("POCKETWIKI_WRITE_TOKEN", environment: environment, fileValues: fileValues),
            writeMaxBytes: max(
                Int(value("POCKETWIKI_WRITE_MAX_BYTES", environment: environment, fileValues: fileValues)) ?? minimumWriteRequestBytes,
                minimumWriteRequestBytes
            ),
            lmStudioBaseURL: value("LM_STUDIO_BASE_URL", environment: environment, fileValues: fileValues, fallback: LocalAIEndpointPolicy.defaultBaseURL).trimmedSlash,
            lmStudioAPIKey: value("LM_STUDIO_API_KEY", environment: environment, fileValues: fileValues)
                .ifEmpty(value("LM_API_TOKEN", environment: environment, fileValues: fileValues)),
            lmStudioModel: value("LM_STUDIO_MODEL", environment: environment, fileValues: fileValues),
            pocketKernelBaseURL: value("POCKETKERNEL_BASE_URL", environment: environment, fileValues: fileValues, fallback: defaultPocketKernelBaseURL).trimmedSlash,
            middlewareAuthBaseURL: value("MIDDLEWARE_BASE_URL", environment: environment, fileValues: fileValues, fallback: defaultMiddlewareAuthBaseURL).trimmedSlash,
            middlewareAuthClientToken: value("MIDDLEWARE_CLIENT_TOKEN", environment: environment, fileValues: fileValues),
            middlewareAuthProjectID: value("MIDDLEWARE_PROJECT_ID", environment: environment, fileValues: fileValues)
                .ifEmpty(value("MCP_DEFAULT_PROJECT_ID", environment: environment, fileValues: fileValues, fallback: "acme")),
            middlewareAuthProfileID: value("MIDDLEWARE_LLM_PROFILE_ID", environment: environment, fileValues: fileValues)
                .ifEmpty(value("MCP_LMSTUDIO_PROFILE_ID", environment: environment, fileValues: fileValues, fallback: "default")),
            envPath: envPath?.path
        )
    }

    static func parseEnv(_ raw: String) -> [String: String] {
        LocalAIRuntimeConfigurationLoader.parseEnv(raw)
    }

    static func resolvePath(_ rawValue: String) -> String {
        var clean = rawValue.pocketTrimmed
        if clean.isEmpty { clean = defaultReferencePath }

        if clean.hasPrefix("file://"), let url = URL(string: clean), url.isFileURL {
            clean = url.path
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        clean = clean
            .replacingOccurrences(of: #"^\$\{HOME\}(?=/|$)"#, with: home, options: .regularExpression)
            .replacingOccurrences(of: #"^\$HOME(?=/|$)"#, with: home, options: .regularExpression)
            .replacingOccurrences(of: #"^~(?=/|$)"#, with: home, options: .regularExpression)
            .replacingOccurrences(of: #"\\([ ()\[\]{}&;'"`$!#])"#, with: "$1", options: .regularExpression)

        if clean.hasPrefix("/") {
            return URL(fileURLWithPath: clean).standardizedFileURL.path
        }

        let rootPath = Bundle.main.object(forInfoDictionaryKey: "PocketWikiRootPath") as? String
        let base = rootPath?.pocketTrimmed.isEmpty == false ? rootPath! : FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: base).appendingPathComponent(clean).standardizedFileURL.path
    }

    private static func candidateEnvPaths(
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager
    ) -> [URL] {
        var paths: [URL] = []
        appendPath(environment["POCKETWIKI_ENV_PATH"], to: &paths)
        appendPath(bundle.object(forInfoDictionaryKey: "PocketWikiEnvPath") as? String, to: &paths)

        if let rootPath = bundle.object(forInfoDictionaryKey: "PocketWikiRootPath") as? String, !rootPath.pocketTrimmed.isEmpty {
            paths.append(URL(fileURLWithPath: rootPath).appendingPathComponent(".env"))
        }

        paths.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".env"))
        paths.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))
        paths.append(bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env"))

        var seen = Set<String>()
        return paths.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func appendPath(_ value: String?, to paths: inout [URL]) {
        guard let value = value?.pocketTrimmed, !value.isEmpty else { return }
        paths.append(URL(fileURLWithPath: value))
    }

    private static func value(
        _ key: String,
        environment: [String: String],
        fileValues: [String: String],
        fallback: String = ""
    ) -> String {
        if let value = environment[key] { return value }
        if let value = fileValues[key] { return value }
        return fallback
    }

    private static func boolValue(
        _ key: String,
        environment: [String: String],
        fileValues: [String: String],
        fallback: Bool
    ) -> Bool {
        let raw = value(key, environment: environment, fileValues: fileValues, fallback: fallback ? "true" : "false")
        return !["false", "0", "no", "nao"].contains(raw.pocketTrimmed.lowercased())
    }
}

private extension String {
    var trimmedSlash: String {
        replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }

    func ifEmpty(_ fallback: String) -> String {
        pocketTrimmed.isEmpty ? fallback : self
    }
}
