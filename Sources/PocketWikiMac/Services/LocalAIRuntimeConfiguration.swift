import Foundation

struct LocalAIRuntimeConfiguration: Hashable, Sendable {
    let baseURL: String
    let apiKey: String
    let modelID: String
    let sourcePath: String?

    var hasToken: Bool {
        !apiKey.pocketTrimmed.isEmpty
    }

    static let empty = LocalAIRuntimeConfiguration(
        baseURL: LocalAIEndpointPolicy.defaultBaseURL,
        apiKey: "",
        modelID: "",
        sourcePath: nil
    )
}

enum LocalAIRuntimeConfigurationLoader {
    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> LocalAIRuntimeConfiguration {
        let envFile = EnvironmentFileReader.firstReadable(
            in: candidateEnvPaths(environment: environment, bundle: bundle, fileManager: fileManager),
            fileManager: fileManager
        )
        let fileValues = envFile.map { parseEnv($0.contents) } ?? [:]

        return LocalAIRuntimeConfiguration(
            baseURL: value("LM_STUDIO_BASE_URL", environment: environment, fileValues: fileValues, fallback: LocalAIEndpointPolicy.defaultBaseURL),
            apiKey: value("LM_STUDIO_API_KEY", environment: environment, fileValues: fileValues)
                .ifEmpty(value("LM_API_TOKEN", environment: environment, fileValues: fileValues)),
            modelID: value("LM_STUDIO_MODEL", environment: environment, fileValues: fileValues),
            sourcePath: envFile?.url.path
        )
    }

    static func parseEnv(_ raw: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            var clean = line.pocketTrimmed
            if clean.hasPrefix("export ") {
                clean = String(clean.dropFirst(7)).pocketTrimmed
            }
            guard !clean.isEmpty, !clean.hasPrefix("#"), let separator = clean.firstIndex(of: "=") else {
                continue
            }

            let key = String(clean[..<separator]).pocketTrimmed
            var value = String(clean[clean.index(after: separator)...]).pocketTrimmed
            if let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
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

        let bundleURL = bundle.bundleURL
        paths.append(bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))

        var seen = Set<String>()
        return paths.filter { url in
            let key = url.standardizedFileURL.path
            if seen.contains(key) { return false }
            seen.insert(key)
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
        if let value = environment[key] {
            return value
        }
        if let value = fileValues[key] {
            return value
        }
        return fallback
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        pocketTrimmed.isEmpty ? fallback : self
    }
}
