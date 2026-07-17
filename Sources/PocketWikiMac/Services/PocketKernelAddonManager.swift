import Foundation
import Observation

enum PocketKernelAddonStatus: Equatable, Sendable {
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
        case .checking: "Procurando PocketKernel..."
        case .starting: "Iniciando PocketKernel empacotado..."
        case .external: "PocketKernel externo online"
        case .managed: "PocketKernel gerenciado pelo PocketWiki"
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
final class PocketKernelAddonManager {
    private struct RestartContext {
        let configuration: PocketWikiServerConfiguration
        let baseURL: String
        let evidence: PocketWikiMCPEvidenceStatus
        let providerRoute: PocketKernelProviderRoute
    }

    private static let restartLimit = 3
    private static let restartWindow: TimeInterval = 60

    private(set) var status: PocketKernelAddonStatus = .idle
    private(set) var healthAvailable = false
    private(set) var mcpAvailable = false
    private(set) var providerAvailable = false
    private(set) var activeEndpoint: URL?
    private(set) var configuredEvidence: PocketWikiMCPEvidenceStatus?
    private(set) var detail = ""
    private(set) var integrityStatus: PocketAddonIntegrityStatus = .notChecked

    private var process: Process?
    private var processLogHandle: FileHandle?
    private var activeBaseURL: URL?
    private let providerBridge = PocketKernelProviderBridge()
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

    func start(
        configuration: PocketWikiServerConfiguration,
        baseURL rawBaseURL: String,
        evidence: PocketWikiMCPEvidenceStatus,
        providerRoute: PocketKernelProviderRoute
    ) async {
        guard configuration.pocketKernelAddonMode != .disabled else {
            stop()
            status = .disabled
            integrityStatus = .notChecked
            detail = "PocketWiki e os demais projetos Pocket continuam funcionando de forma independente."
            return
        }

        guard let baseURL = normalizedBaseURL(rawBaseURL),
              let kernelURL = try? PocketKernelEndpointPolicy.kernelURL(baseURL.absoluteString) else {
            status = .failed("URL do PocketKernel inválida ou fora da política local")
            return
        }

        if configuration.pocketKernelAddonMode == .external || activeBaseURL != baseURL {
            stop()
        }

        if activeBaseURL == baseURL, process?.isRunning == true, await isHealthy(kernelURL) {
            providerBridge.update(configuration: providerRoute)
            healthAvailable = true
            providerAvailable = providerBridge.isReady
            activeEndpoint = kernelURL
            status = .managed
            restartContext = RestartContext(
                configuration: configuration,
                baseURL: rawBaseURL,
                evidence: evidence,
                providerRoute: providerRoute
            )
            return
        }

        status = .checking
        if await isHealthy(kernelURL) {
            stop()
            activeBaseURL = baseURL
            activeEndpoint = kernelURL
            healthAvailable = true
            providerAvailable = false
            integrityStatus = .externalUntracked
            status = .external
            detail = "Serviço HTTP validado. O processo e o MCP continuam sob responsabilidade da instância externa."
            return
        }

        guard configuration.pocketKernelAddonMode != .external else {
            status = .unavailable("instância remota não respondeu em \(kernelURL.absoluteString)")
            return
        }
        guard isManagedLoopbackURL(baseURL) else {
            status = .unavailable("o modo gerenciado aceita somente HTTP em loopback")
            return
        }
        guard let executableURL = executableURL(configuration: configuration) else {
            status = .unavailable("executável não foi empacotado; use um PocketKernel externo ou prepare o add-on")
            return
        }

        do {
            stop()
            let locations = try managedLocations()
            integrityStatus = try PocketAddonBuildInspector.inspect(
                executableURL: executableURL,
                service: .pocketKernel
            )
            let mcp: PreparedMCP
            do {
                mcp = try prepareMCP(
                    configuration: configuration,
                    evidence: evidence,
                    locations: locations
                )
            } catch {
                mcp = PreparedMCP(
                    wrapperURL: nil,
                    evidence: unavailableEvidence(from: evidence, reason: error.localizedDescription)
                )
            }
            let providerRuntime = try await providerBridge.start(configuration: providerRoute)
            let logURL = locations.addonDirectory.appendingPathComponent("pocketkernel.log")
            let logHandle = try Self.makeProcessLog(at: logURL)
            let child = Process()
            child.executableURL = executableURL
            child.arguments = ["-mode", "serve", "-addr", listenAddress(baseURL)]
            child.currentDirectoryURL = locations.addonDirectory
            child.environment = managedEnvironment(
                configuration: configuration,
                wrapperURL: mcp.wrapperURL,
                providerRuntime: providerRuntime,
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
            configuredEvidence = mcp.evidence
            mcpAvailable = mcp.evidence.available
            providerAvailable = true
            detail = mcp.evidence.available
                ? "HTTP e MCP Evidence iniciados juntos; o MCP permanece stdio e restrito ao mesmo host."
                : "Kernel iniciado sem MCP funcional: \(mcp.evidence.status)."
            status = .starting

            let readinessDeadline = Date().addingTimeInterval(5)
            repeat {
                if await isHealthy(kernelURL) {
                    healthAvailable = true
                    activeEndpoint = kernelURL
                    status = .managed
                    restartContext = RestartContext(
                        configuration: configuration,
                        baseURL: rawBaseURL,
                        evidence: evidence,
                        providerRoute: providerRoute
                    )
                    return
                }
                if !child.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            } while Date() < readinessDeadline

            let reason = child.isRunning
                ? "sonda HTTP não ficou pronta em 5 segundos"
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
        providerBridge.stop()
        activeBaseURL = nil
        activeEndpoint = nil
        restartContext = nil
        healthAvailable = false
        mcpAvailable = false
        providerAvailable = false
        configuredEvidence = nil
        detail = ""
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
        providerBridge.stop()
        activeEndpoint = nil
        healthAvailable = false
        mcpAvailable = false
        providerAvailable = false
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
            detail = reason
            eventHandler?(
                PocketAddonRuntimeEvent(
                    service: .pocketKernel,
                    level: .warning,
                    message: reason + diagnosis,
                    presentsAlert: false
                )
            )
            guard let context else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.restartDelay(for: attempt))
                guard let self else { return }
                await self.start(
                    configuration: context.configuration,
                    baseURL: context.baseURL,
                    evidence: context.evidence,
                    providerRoute: context.providerRoute
                )
                self.finishAutomaticRecovery(attempt: attempt)
            }
            return
        }

        let reason = attempt > Self.restartLimit
            ? "o processo encerrou repetidamente; recuperação automática suspensa após \(Self.restartLimit) tentativas em 60 segundos"
            : "o processo encerrou inesperadamente e não há configuração gerenciada para reiniciá-lo"
        status = .failed(reason)
        detail = reason
        eventHandler?(
            PocketAddonRuntimeEvent(
                service: .pocketKernel,
                level: .error,
                message: reason + ". Consulte pocketkernel.log para o diagnóstico completo.",
                presentsAlert: true
            )
        )
    }

    private func finishAutomaticRecovery(attempt: Int) {
        if status == .managed {
            eventHandler?(
                PocketAddonRuntimeEvent(
                    service: .pocketKernel,
                    level: .info,
                    message: "processo reiniciado automaticamente na tentativa \(attempt)/\(Self.restartLimit)",
                    presentsAlert: false
                )
            )
            return
        }

        if status == .external, healthAvailable {
            eventHandler?(
                PocketAddonRuntimeEvent(
                    service: .pocketKernel,
                    level: .warning,
                    message: "endpoint recuperado por uma instância externa; o PocketWiki deixou de gerenciar o processo",
                    presentsAlert: false
                )
            )
            return
        }

        let reason = status.failureReason ?? status.title
        status = .failed(reason)
        detail = reason
        eventHandler?(
            PocketAddonRuntimeEvent(
                service: .pocketKernel,
                level: .error,
                message: "não foi possível recuperar o add-on automaticamente: \(reason). Consulte pocketkernel.log.",
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

    private func executableURL(configuration: PocketWikiServerConfiguration) -> URL? {
        var candidates: [URL] = []
        if !configuration.pocketKernelAddonBinaryPath.isEmpty {
            candidates.append(URL(fileURLWithPath: configuration.pocketKernelAddonBinaryPath))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pocketkernel"))
        if let resources = PocketWikiResourceBundle.resourceURL {
            candidates.append(resources.appendingPathComponent("Addons/PocketKernel/pocketkernel"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func prepareMCP(
        configuration: PocketWikiServerConfiguration,
        evidence: PocketWikiMCPEvidenceStatus,
        locations: ManagedLocations
    ) throws -> PreparedMCP {
        guard evidence.status != "mcp_script_missing",
              evidence.status != "missing",
              evidence.status != "not_directory" else {
            throw PocketKernelAddonError.mcpUnavailable(evidence.status)
        }
        guard let nodeURL = nodeExecutableURL(configuration: configuration) else {
            throw PocketKernelAddonError.nodeUnavailable
        }
        guard evidence.args.count >= 3 else {
            throw PocketKernelAddonError.mcpContractInvalid
        }

        let scriptURL = URL(fileURLWithPath: evidence.args[0])
        let rootURL = URL(fileURLWithPath: evidence.args[2])
        let wrapperURL = locations.addonDirectory.appendingPathComponent("pocketwiki-mcp-wrapper")
        let wrapper = """
        #!/bin/sh
        exec \(shellQuote(nodeURL.path)) \(shellQuote(scriptURL.path)) --root \(shellQuote(rootURL.path))
        """
        guard FileManager.default.createFile(
            atPath: wrapperURL.path,
            contents: Data(wrapper.utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw PocketKernelAddonError.wrapperUnavailable
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapperURL.path)

        let wrappedEvidence = PocketWikiMCPEvidenceStatus(
            available: true,
            transport: "stdio",
            status: "ready",
            command: wrapperURL.path,
            args: [],
            tools: PocketWikiMCPEvidenceStatus.toolNames,
            timeoutMs: PocketWikiMCPEvidenceStatus.timeoutMs,
            maxResults: PocketWikiMCPEvidenceStatus.maxResults,
            sameHostOnly: true,
            argsParsing: "wrapper_argv_preserved",
            argsPortable: true,
            note: "PocketKernel gerenciado inicia o MCP sob demanda via wrapper; não há porta MCP separada."
        )
        return PreparedMCP(wrapperURL: wrapperURL, evidence: wrappedEvidence)
    }

    private func unavailableEvidence(
        from evidence: PocketWikiMCPEvidenceStatus,
        reason: String
    ) -> PocketWikiMCPEvidenceStatus {
        PocketWikiMCPEvidenceStatus(
            available: false,
            transport: evidence.transport,
            status: evidence.status == "ready" ? "addon_setup_failed" : evidence.status,
            command: evidence.command,
            args: evidence.args,
            tools: evidence.tools,
            timeoutMs: evidence.timeoutMs,
            maxResults: evidence.maxResults,
            sameHostOnly: evidence.sameHostOnly,
            argsParsing: evidence.argsParsing,
            argsPortable: evidence.argsPortable,
            note: "PocketKernel iniciou sem MCP Evidence: \(reason)"
        )
    }

    private func nodeExecutableURL(configuration: PocketWikiServerConfiguration) -> URL? {
        var candidates: [String] = []
        if !configuration.pocketKernelNodeBinaryPath.isEmpty {
            candidates.append(configuration.pocketKernelNodeBinaryPath)
        }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/node" }
        }
        return candidates.lazy
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func managedEnvironment(
        configuration: PocketWikiServerConfiguration,
        wrapperURL: URL?,
        providerRuntime: PocketKernelProviderBridgeRuntime,
        inherited: [String: String]
    ) -> [String: String] {
        var environment = inherited
        if let wrapperURL {
            environment["POCKETKERNEL_WIKI_MCP_COMMAND"] = wrapperURL.path
            environment["POCKETKERNEL_WIKI_MCP_ARGS"] = ""
            environment["POCKETKERNEL_WIKI_MCP_TIMEOUT_MS"] = String(PocketWikiMCPEvidenceStatus.timeoutMs)
            environment["POCKETKERNEL_WIKI_MCP_MAX_RESULTS"] = String(PocketWikiMCPEvidenceStatus.maxResults)
        } else {
            environment.removeValue(forKey: "POCKETKERNEL_WIKI_MCP_COMMAND")
            environment.removeValue(forKey: "POCKETKERNEL_WIKI_MCP_ARGS")
        }
        environment["POCKETKERNEL_LLM_BASE_URL"] = providerRuntime.baseURL.absoluteString
        environment["POCKETKERNEL_LLM_MODEL"] = ""
        environment["POCKETKERNEL_LLM_API_KEY"] = providerRuntime.bearerToken
        environment["MIDDLEWARE_BASE_URL"] = configuration.middlewareAuthBaseURL
        environment["MIDDLEWARE_CLIENT_TOKEN"] = configuration.middlewareAuthClientToken
        environment["MIDDLEWARE_PROJECT_ID"] = configuration.middlewareAuthProjectID
        environment["MIDDLEWARE_LLM_PROFILE_ID"] = configuration.middlewareAuthProfileID
        environment.removeValue(forKey: "POCKETWIKI_POCKETKERNEL_BINARY")
        return environment
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
        return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    private func listenAddress(_ baseURL: URL) -> String {
        let host = baseURL.host ?? "127.0.0.1"
        let printableHost = host.contains(":") ? "[\(host)]" : host
        return "\(printableHost):\(baseURL.port ?? 8080)"
    }

    private func isHealthy(_ kernelURL: URL) async -> Bool {
        var request = URLRequest(url: kernelURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.7
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 405
        } catch {
            return false
        }
    }

    private func managedLocations() throws -> ManagedLocations {
        let applicationSupport = try applicationSupportOverride ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let addonDirectory = applicationSupport
            .appendingPathComponent("PocketWiki", isDirectory: true)
            .appendingPathComponent("PocketKernel", isDirectory: true)
        try FileManager.default.createDirectory(
            at: addonDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: addonDirectory.path)
        return ManagedLocations(addonDirectory: addonDirectory)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private struct PreparedMCP {
    let wrapperURL: URL?
    let evidence: PocketWikiMCPEvidenceStatus
}

private struct ManagedLocations {
    let addonDirectory: URL
}

private enum PocketKernelAddonError: LocalizedError {
    case nodeUnavailable
    case mcpUnavailable(String)
    case mcpContractInvalid
    case wrapperUnavailable

    var errorDescription: String? {
        switch self {
        case .nodeUnavailable: "Node.js não foi encontrado para iniciar o MCP Evidence"
        case .mcpUnavailable(let status): "MCP Evidence indisponível: \(status)"
        case .mcpContractInvalid: "contrato de argumentos do MCP Evidence é inválido"
        case .wrapperUnavailable: "não foi possível criar o wrapper seguro do MCP Evidence"
        }
    }
}
