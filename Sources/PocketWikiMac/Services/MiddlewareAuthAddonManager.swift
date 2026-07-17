import Foundation
import Observation

enum MiddlewareAuthAddonStatus: Equatable, Sendable {
    case idle
    case disabled
    case checking
    case starting
    case external
    case managed
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Add-on ainda não consultado"
        case .disabled: "Add-on desabilitado"
        case .checking: "Procurando MiddlewareAuth..."
        case .starting: "Iniciando MiddlewareAuth empacotado..."
        case .external: "MiddlewareAuth externo online"
        case .managed: "MiddlewareAuth gerenciado pelo PocketWiki"
        case .unavailable(let reason): "Add-on indisponível: \(reason)"
        case .failed(let reason): "Falha no add-on: \(reason)"
        }
    }

    var isReady: Bool {
        self == .external || self == .managed
    }

    var failureReason: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): reason
        default: nil
        }
    }
}

@MainActor
@Observable
final class MiddlewareAuthAddonManager {
    private struct RestartContext {
        let configuration: PocketWikiServerConfiguration
        let baseURL: String
    }

    private static let restartLimit = 3
    private static let restartWindow: TimeInterval = 60

    private(set) var status: MiddlewareAuthAddonStatus = .idle
    private(set) var clientToken = ""
    private(set) var healthAvailable = false
    private(set) var accessVerified = false
    private(set) var activeEndpoint: URL?
    private(set) var integrityStatus: PocketAddonIntegrityStatus = .notChecked

    private var process: Process?
    private var processLogHandle: FileHandle?
    private var activeBaseURL: URL?
    private let applicationSupportOverride: URL?
    private var eventHandler: (@MainActor (PocketAddonRuntimeEvent) -> Void)?
    private var restartContext: RestartContext?
    private var unexpectedTerminationDates: [Date] = []

    init(applicationSupportURL: URL? = nil) {
        applicationSupportOverride = applicationSupportURL
    }

    func setEventHandler(_ handler: @escaping @MainActor (PocketAddonRuntimeEvent) -> Void) {
        eventHandler = handler
    }

    func start(configuration: PocketWikiServerConfiguration, baseURL rawBaseURL: String) async {
        guard configuration.middlewareAuthAddonMode != .disabled else {
            stop()
            status = .disabled
            integrityStatus = .notChecked
            return
        }

        guard let baseURL = normalizedBaseURL(rawBaseURL) else {
            status = .failed("URL do MiddlewareAuth inválida")
            return
        }

        if configuration.middlewareAuthAddonMode == .external || activeBaseURL != baseURL {
            stop()
        }

        if activeBaseURL == baseURL, process?.isRunning == true, await isHealthy(baseURL) {
            healthAvailable = true
            accessVerified = await isAuthorized(
                baseURL,
                token: clientToken,
                projectID: configuration.middlewareAuthProjectID,
                profileID: configuration.middlewareAuthProfileID
            )
            if accessVerified {
                status = .managed
                restartContext = RestartContext(configuration: configuration, baseURL: rawBaseURL)
            } else {
                stop()
                status = .failed("helper online, mas a senha foi recusada")
            }
            return
        }

        status = .checking
        if await isHealthy(baseURL) {
            stop()
            activeBaseURL = baseURL
            activeEndpoint = baseURL
            healthAvailable = true
            clientToken = configuration.middlewareAuthClientToken
            if clientToken.isEmpty,
               configuration.middlewareAuthAddonMode == .automatic,
               isManagedLoopbackURL(baseURL) {
                clientToken = existingManagedClientToken() ?? ""
            }
            accessVerified = await isAuthorized(
                baseURL,
                token: clientToken,
                projectID: configuration.middlewareAuthProjectID,
                profileID: configuration.middlewareAuthProfileID
            )
            integrityStatus = .externalUntracked
            status = .external
            return
        }

        guard configuration.middlewareAuthAddonMode != .external else {
            status = .unavailable("instância externa não respondeu em \(baseURL.absoluteString)")
            return
        }
        guard isManagedLoopbackURL(baseURL) else {
            status = .unavailable("o modo gerenciado aceita somente HTTP em loopback")
            return
        }
        guard let executableURL = executableURL(configuration: configuration) else {
            status = .unavailable("executável não foi empacotado; use uma instância externa ou prepare o add-on")
            return
        }

        do {
            stop()
            let credentials = try loadOrCreateCredentials()
            integrityStatus = try PocketAddonBuildInspector.inspect(
                executableURL: executableURL,
                service: .middlewareAuth
            )
            let logURL = credentials.stateDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("middleware-auth.log")
            let logHandle = try Self.makeProcessLog(at: logURL)
            let child = Process()
            child.executableURL = executableURL
            child.currentDirectoryURL = credentials.stateDirectory.deletingLastPathComponent()
            child.environment = managedEnvironment(
                baseURL: baseURL,
                credentials: credentials,
                inherited: ProcessInfo.processInfo.environment
            )
            child.standardOutput = logHandle
            child.standardError = logHandle
            child.terminationHandler = { [weak self] terminated in
                let exitCode = terminated.terminationStatus
                Task { @MainActor [weak self] in
                    self?.handleUnexpectedTermination(
                        process: terminated,
                        exitCode: exitCode,
                        logURL: logURL
                    )
                }
            }
            try child.run()

            process = child
            processLogHandle = logHandle
            activeBaseURL = baseURL
            clientToken = credentials.clientToken
            status = .starting

            let readinessDeadline = Date().addingTimeInterval(5)
            repeat {
                if await isHealthy(baseURL) {
                    healthAvailable = true
                    activeEndpoint = baseURL
                    accessVerified = await isAuthorized(
                        baseURL,
                        token: credentials.clientToken,
                        projectID: configuration.middlewareAuthProjectID,
                        profileID: configuration.middlewareAuthProfileID
                    )
                    if accessVerified {
                        status = .managed
                        restartContext = RestartContext(configuration: configuration, baseURL: rawBaseURL)
                        return
                    }
                    stop()
                    status = .failed("helper iniciou, mas recusou a senha gerada")
                    return
                }
                if !child.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            } while Date() < readinessDeadline

            let reason = child.isRunning
                ? "health check não ficou pronto em 5 segundos"
                : "processo encerrou durante a inicialização"
            stop()
            status = .failed(reason)
        } catch {
            stop()
            integrityStatus = .failed(error.localizedDescription)
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        let child = process
        process = nil
        if let child, child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
        try? processLogHandle?.close()
        processLogHandle = nil
        activeBaseURL = nil
        activeEndpoint = nil
        restartContext = nil
        clientToken = ""
        healthAvailable = false
        accessVerified = false
    }

    var managedProcessID: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private func handleUnexpectedTermination(process terminated: Process, exitCode: Int32, logURL: URL) {
        guard self.process === terminated, status == .managed else { return }
        let context = restartContext
        self.process = nil
        restartContext = nil
        try? processLogHandle?.close()
        processLogHandle = nil
        activeEndpoint = nil
        healthAvailable = false
        accessVerified = false
        let tail = Self.processLogTail(from: logURL)
        let now = Date()
        unexpectedTerminationDates = unexpectedTerminationDates.filter {
            now.timeIntervalSince($0) < Self.restartWindow
        }
        unexpectedTerminationDates.append(now)
        let attempt = unexpectedTerminationDates.count
        let canRestart = context != nil && attempt <= Self.restartLimit
        let diagnosis = tail.isEmpty ? "" : " Diagnóstico: \(tail)"

        if canRestart {
            let reason = "processo encerrou inesperadamente (exit \(exitCode)); tentando recuperar automaticamente (\(attempt)/\(Self.restartLimit))."
            status = .failed(reason)
            eventHandler?(
                PocketAddonRuntimeEvent(
                    service: .middlewareAuth,
                    level: .warning,
                    message: reason + diagnosis,
                    presentsAlert: false
                )
            )
            guard let context else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.restartDelay(for: attempt))
                guard let self else { return }
                await self.start(configuration: context.configuration, baseURL: context.baseURL)
                self.finishAutomaticRecovery(attempt: attempt)
            }
            return
        }

        let reason = attempt > Self.restartLimit
            ? "o processo encerrou repetidamente; recuperação automática suspensa após \(Self.restartLimit) tentativas em 60 segundos"
            : "o processo encerrou inesperadamente e não há configuração gerenciada para reiniciá-lo"
        status = .failed(reason)
        eventHandler?(
            PocketAddonRuntimeEvent(
                service: .middlewareAuth,
                level: .error,
                message: reason + ". Consulte middleware-auth.log para o diagnóstico completo.",
                presentsAlert: true
            )
        )
    }

    private func finishAutomaticRecovery(attempt: Int) {
        if status == .managed {
            eventHandler?(
                PocketAddonRuntimeEvent(
                    service: .middlewareAuth,
                    level: .info,
                    message: "processo reiniciado automaticamente na tentativa \(attempt)/\(Self.restartLimit)",
                    presentsAlert: false
                )
            )
            return
        }

        if status == .external, healthAvailable, accessVerified {
            eventHandler?(
                PocketAddonRuntimeEvent(
                    service: .middlewareAuth,
                    level: .warning,
                    message: "endpoint recuperado por uma instância externa autorizada; o PocketWiki deixou de gerenciar o processo",
                    presentsAlert: false
                )
            )
            return
        }

        let reason: String
        if status == .external, healthAvailable, !accessVerified {
            reason = "outra instância ocupou o endpoint, mas recusou a credencial configurada"
        } else {
            reason = status.failureReason ?? status.title
        }
        status = .failed(reason)
        eventHandler?(
            PocketAddonRuntimeEvent(
                service: .middlewareAuth,
                level: .error,
                message: "não foi possível recuperar o add-on automaticamente: \(reason). Consulte middleware-auth.log.",
                presentsAlert: true
            )
        )
    }

    private static func restartDelay(for attempt: Int) -> Duration {
        switch attempt {
        case 1: .seconds(1)
        case 2: .seconds(5)
        default: .seconds(15)
        }
    }

    private static func makeProcessLog(at url: URL) throws -> FileHandle {
        _ = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        return try FileHandle(forWritingTo: url)
    }

    private static func processLogTail(from url: URL) -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let tail = raw.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " | ")
        return String(tail.prefix(600))
            .replacingOccurrences(
                of: #"(?i)(bearer\s+)[^\s]+"#,
                with: "$1<redacted>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"sk-[A-Za-z0-9:_-]+"#,
                with: "<redacted>",
                options: .regularExpression
            )
    }

    func rotateManagedClientToken(
        configuration: PocketWikiServerConfiguration,
        baseURL rawBaseURL: String
    ) async throws -> String {
        guard let baseURL = normalizedBaseURL(rawBaseURL), isManagedLoopbackURL(baseURL) else {
            throw MiddlewareAuthAddonError.managedLoopbackRequired
        }

        var managedConfiguration = configuration
        managedConfiguration.middlewareAuthAddonMode = .managed
        await start(configuration: managedConfiguration, baseURL: rawBaseURL)
        guard status == .managed, process?.isRunning == true else {
            throw MiddlewareAuthAddonError.managedProcessRequired
        }

        let current = try loadOrCreateCredentials()
        let rotated = ManagedCredentials(
            stateDirectory: current.stateDirectory,
            secretKey: current.secretKey,
            clientToken: Self.randomCredential()
        )
        try persistCredentials(rotated)

        stop()
        for _ in 0..<30 {
            if !(await isHealthy(baseURL)) { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        managedConfiguration.middlewareAuthClientToken = rotated.clientToken
        await start(configuration: managedConfiguration, baseURL: rawBaseURL)
        guard status == .managed, accessVerified else {
            try? persistCredentials(current)
            stop()
            for _ in 0..<30 {
                if !(await isHealthy(baseURL)) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            managedConfiguration.middlewareAuthClientToken = current.clientToken
            await start(configuration: managedConfiguration, baseURL: rawBaseURL)
            throw MiddlewareAuthAddonError.passwordRotationFailed
        }
        return rotated.clientToken
    }

    private func executableURL(configuration: PocketWikiServerConfiguration) -> URL? {
        var candidates: [URL] = []
        if !configuration.middlewareAuthAddonBinaryPath.isEmpty {
            candidates.append(URL(fileURLWithPath: configuration.middlewareAuthAddonBinaryPath))
        }
        if let helpersURL = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent().appendingPathComponent("Helpers") {
            candidates.append(helpersURL.appendingPathComponent("middleware-codex-oauth"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/middleware-codex-oauth"))
        if let resources = PocketWikiResourceBundle.resourceURL {
            candidates.append(resources.appendingPathComponent("Addons/MiddlewareAuth/middleware-codex-oauth"))
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func normalizedBaseURL(_ rawValue: String) -> URL? {
        guard var components = URLComponents(string: rawValue.pocketTrimmed),
              components.scheme != nil,
              components.host != nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func isManagedLoopbackURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        switch url.host?.lowercased() {
        case "127.0.0.1", "localhost", "::1": return true
        default: return false
        }
    }

    private func isHealthy(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        request.timeoutInterval = 0.6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        do {
            let (data, response) = try await lifecycleData(for: request, timeout: 0.6)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONDecoder().decode(HealthPayload.self, from: data) else {
                return false
            }
            return payload.status == "ok" && payload.checks.contains { $0.name == "http" && $0.status == "ok" }
        } catch {
            return false
        }
    }

    private func isAuthorized(
        _ baseURL: URL,
        token: String,
        projectID: String,
        profileID: String
    ) async -> Bool {
        let cleanToken = token.pocketTrimmed
        guard !cleanToken.isEmpty else { return false }
        let project = MiddlewareAuthEndpointPolicy.pathSegment(projectID, fallback: "acme")
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("v1/projects")
                .appendingPathComponent(project)
                .appendingPathComponent("auth/openai/status"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "profileId", value: profileID.pocketTrimmed.pocketIfEmpty("default"))
        ]
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await lifecycleData(for: request, timeout: 1.5)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func lifecycleData(
        for request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }

    private func managedEnvironment(
        baseURL: URL,
        credentials: ManagedCredentials,
        inherited: [String: String]
    ) -> [String: String] {
        var environment = inherited
        let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let port = components?.port ?? 80
        environment["NODE_ENV"] = "production"
        environment["HTTP_BIND_ADDR"] = components?.host ?? "127.0.0.1"
        environment["HTTP_PORT"] = String(port)
        environment["OAUTH_CALLBACK_HOST"] = components?.host ?? "localhost"
        environment["OAUTH_CALLBACK_PORT"] = String(port)
        environment["MIDDLEWARE_STATE_DIR"] = credentials.stateDirectory.path
        environment["MIDDLEWARE_SECRET_KEY"] = credentials.secretKey
        environment["MIDDLEWARE_CLIENT_TOKEN"] = credentials.clientToken
        environment["MIDDLEWARE_REDACT_LOGS"] = "true"
        environment.removeValue(forKey: "POCKETWIKI_MIDDLEWARE_AUTH_BINARY")
        return environment
    }

    private func loadOrCreateCredentials() throws -> ManagedCredentials {
        let locations = try managedLocations(create: true)
        if let credentials = readCredentials(
            from: locations.credentialsURL,
            stateDirectory: locations.stateDirectory
        ) {
            return credentials
        }

        let credentials = ManagedCredentials(
            stateDirectory: locations.stateDirectory,
            secretKey: Self.randomCredential(),
            clientToken: Self.randomCredential()
        )
        try persistCredentials(credentials, locations: locations)
        return credentials
    }

    private func persistCredentials(_ credentials: ManagedCredentials) throws {
        let locations = try managedLocations(create: true)
        try persistCredentials(credentials, locations: locations)
    }

    private func persistCredentials(
        _ credentials: ManagedCredentials,
        locations: ManagedLocations
    ) throws {
        let contents = Data("secret=\(credentials.secretKey)\ntoken=\(credentials.clientToken)\n".utf8)
        if FileManager.default.fileExists(atPath: locations.credentialsURL.path) {
            try FileManager.default.removeItem(at: locations.credentialsURL)
        }
        guard FileManager.default.createFile(
            atPath: locations.credentialsURL.path,
            contents: contents,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MiddlewareAuthAddonError.credentialsUnavailable
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: locations.credentialsURL.path
        )
    }

    private func existingManagedClientToken() -> String? {
        guard let locations = try? managedLocations(create: false) else { return nil }
        return readCredentials(
            from: locations.credentialsURL,
            stateDirectory: locations.stateDirectory
        )?.clientToken
    }

    private func managedLocations(create: Bool) throws -> ManagedLocations {
        let applicationSupport = try applicationSupportOverride ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let addonDirectory = applicationSupport
            .appendingPathComponent("PocketWiki", isDirectory: true)
            .appendingPathComponent("MiddlewareAuth", isDirectory: true)
        let stateDirectory = addonDirectory.appendingPathComponent("state", isDirectory: true)
        let credentialsURL = addonDirectory.appendingPathComponent("pocketwiki-addon.credentials")
        if create {
            try secureDirectory(addonDirectory)
            try secureDirectory(stateDirectory)
        }
        return ManagedLocations(stateDirectory: stateDirectory, credentialsURL: credentialsURL)
    }

    private func secureDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MiddlewareAuthAddonError.insecureStateDirectory
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func readCredentials(from url: URL, stateDirectory: URL) -> ManagedCredentials? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let values = Self.parseCredentials(raw)
        guard let secretKey = values["secret"], secretKey.count >= 32,
              let clientToken = values["token"], clientToken.count >= 32 else {
            return nil
        }
        return ManagedCredentials(
            stateDirectory: stateDirectory,
            secretKey: secretKey,
            clientToken: clientToken
        )
    }

    private static func parseCredentials(_ raw: String) -> [String: String] {
        raw.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
    }

    private static func randomCredential() -> String {
        (UUID().uuidString + UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
    }
}

private struct ManagedCredentials {
    let stateDirectory: URL
    let secretKey: String
    let clientToken: String
}

private struct ManagedLocations {
    let stateDirectory: URL
    let credentialsURL: URL
}

private enum MiddlewareAuthAddonError: LocalizedError {
    case credentialsUnavailable
    case insecureStateDirectory
    case managedLoopbackRequired
    case managedProcessRequired
    case passwordRotationFailed

    var errorDescription: String? {
        switch self {
        case .credentialsUnavailable: "não foi possível criar as credenciais do add-on"
        case .insecureStateDirectory: "diretório de estado do add-on não é seguro"
        case .managedLoopbackRequired: "senha automática só pode ser gerada para o helper local em loopback"
        case .managedProcessRequired: "não foi possível assumir um helper local; já pode existir um MiddlewareAuth externo nessa URL"
        case .passwordRotationFailed: "a nova senha foi salva, mas o helper não confirmou o acesso"
        }
    }
}

private struct HealthPayload: Decodable {
    let status: String
    let checks: [HealthCheck]

    struct HealthCheck: Decodable {
        let name: String
        let status: String
    }
}
