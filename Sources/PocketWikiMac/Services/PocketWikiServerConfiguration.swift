import Foundation

enum MiddlewareAuthAddonMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case managed
    case external
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automático"
        case .managed: "Neste Mac"
        case .external: "Remoto"
        case .disabled: "Desligado"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Usa um endpoint saudável ou inicia o helper local."
        case .managed: "PocketWiki inicia e encerra o helper em loopback."
        case .external: "Conecta em um MiddlewareAuth iniciado fora deste app."
        case .disabled: "Não consulta nem inicia o MiddlewareAuth."
        }
    }

    static func parse(_ value: String) -> MiddlewareAuthAddonMode {
        switch value.pocketTrimmed.lowercased() {
        case "managed", "gerenciado": .managed
        case "external", "externo": .external
        case "disabled", "off", "desabilitado": .disabled
        default: .automatic
        }
    }
}

enum PocketKernelAddonMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case managed
    case external
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automático"
        case .managed: "Neste Mac"
        case .external: "Remoto"
        case .disabled: "Desligado"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Usa um PocketKernel saudável ou inicia a base local empacotada."
        case .managed: "PocketWiki inicia o Kernel local e conecta o MCP Evidence."
        case .external: "Conecta em um PocketKernel iniciado e administrado separadamente."
        case .disabled: "Não consulta nem inicia o PocketKernel."
        }
    }

    static func parse(_ value: String) -> PocketKernelAddonMode {
        switch value.pocketTrimmed.lowercased() {
        case "managed", "gerenciado": .managed
        case "external", "externo": .external
        case "disabled", "off", "desabilitado": .disabled
        default: .automatic
        }
    }
}

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
    var pocketKernelAddonMode: PocketKernelAddonMode
    var pocketKernelAddonBinaryPath: String
    var pocketKernelNodeBinaryPath: String
    var middlewareAuthBaseURL: String
    var middlewareAuthClientToken: String
    var middlewareAuthProjectID: String
    var middlewareAuthProfileID: String
    var middlewareAuthAddonMode: MiddlewareAuthAddonMode
    var middlewareAuthAddonBinaryPath: String
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
            pocketKernelAddonMode: .automatic,
            pocketKernelAddonBinaryPath: "",
            pocketKernelNodeBinaryPath: "",
            middlewareAuthBaseURL: defaultMiddlewareAuthBaseURL,
            middlewareAuthClientToken: "",
            middlewareAuthProjectID: "acme",
            middlewareAuthProfileID: "default",
            middlewareAuthAddonMode: .automatic,
            middlewareAuthAddonBinaryPath: "",
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
        let envFile = EnvironmentFileReader.firstReadable(
            in: candidateEnvPaths(environment: environment, bundle: bundle, fileManager: fileManager),
            fileManager: fileManager
        )
        let fileValues = envFile.map { parseEnv($0.contents) } ?? [:]

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
            pocketKernelAddonMode: PocketKernelAddonMode.parse(
                value("POCKETWIKI_POCKETKERNEL_MODE", environment: environment, fileValues: fileValues, fallback: "automatic")
            ),
            pocketKernelAddonBinaryPath: Self.resolveOptionalPath(
                value("POCKETWIKI_POCKETKERNEL_BINARY", environment: environment, fileValues: fileValues)
            ),
            pocketKernelNodeBinaryPath: Self.resolveOptionalPath(
                value("POCKETWIKI_NODE_BINARY", environment: environment, fileValues: fileValues)
            ),
            middlewareAuthBaseURL: value("MIDDLEWARE_BASE_URL", environment: environment, fileValues: fileValues, fallback: defaultMiddlewareAuthBaseURL).trimmedSlash,
            middlewareAuthClientToken: value("MIDDLEWARE_CLIENT_TOKEN", environment: environment, fileValues: fileValues),
            middlewareAuthProjectID: value("MIDDLEWARE_PROJECT_ID", environment: environment, fileValues: fileValues)
                .ifEmpty(value("MCP_DEFAULT_PROJECT_ID", environment: environment, fileValues: fileValues, fallback: "acme")),
            middlewareAuthProfileID: value("MIDDLEWARE_LLM_PROFILE_ID", environment: environment, fileValues: fileValues)
                .ifEmpty(value("MCP_LMSTUDIO_PROFILE_ID", environment: environment, fileValues: fileValues, fallback: "default")),
            middlewareAuthAddonMode: MiddlewareAuthAddonMode.parse(
                value("POCKETWIKI_MIDDLEWARE_AUTH_MODE", environment: environment, fileValues: fileValues, fallback: "automatic")
            ),
            middlewareAuthAddonBinaryPath: Self.resolveOptionalPath(
                value("POCKETWIKI_MIDDLEWARE_AUTH_BINARY", environment: environment, fileValues: fileValues)
            ),
            envPath: envFile?.url.path
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

    private static func resolveOptionalPath(_ rawValue: String) -> String {
        rawValue.pocketTrimmed.isEmpty ? "" : resolvePath(rawValue)
    }

    private static func candidateEnvPaths(
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager
    ) -> [URL] {
        var paths: [URL] = []
        appendPath(environment["POCKETWIKI_ENV_PATH"], to: &paths)
        appendPath(bundle.object(forInfoDictionaryKey: "PocketWikiEnvPath") as? String, to: &paths)

        paths.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(".env"))
        paths.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))

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
