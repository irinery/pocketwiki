import Foundation
import Observation

@MainActor
@Observable
final class LocalAIChatSession {
    var messages: [LocalAIChatMessage] = []
    var prompt = ""
    var isStreaming = false
    var statusMessage = "Pronto para conversar com a IA local."
    var errorMessage: String?
    var availableModels: [LocalAIModel] = []
    var lastContext: LocalAIContextPayload?
    var manualSources: [LocalAIManualContextSource] = []
    var excludedContextPaths: Set<String> = []
    var messagesRevision = 0
    var contextRevision = 0
    var isAIMemoryConfigured = false
    private(set) var openAILoginPrompt: MiddlewareAuthOpenAILoginStart?

    private let kernelClient: PocketKernelClient
    private let middlewareAuthClient: MiddlewareAuthClient
    private let conversationStore: PortableConversationStore
    private var aiMemoryConfiguration: AIMemoryConfiguration?
    private var aiMemoryClient: AIMemoryClient?
    private var archiveSession: PortableConversationSession
    private var captureRootPath = FileManager.default.currentDirectoryPath
    private var archiveTask: Task<Void, Never>?
    private var hookDrainTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var loginPollTask: Task<Void, Never>?

    init(
        kernelClient: PocketKernelClient = PocketKernelClient(),
        middlewareAuthClient: MiddlewareAuthClient = MiddlewareAuthClient()
    ) {
        self.kernelClient = kernelClient
        self.middlewareAuthClient = middlewareAuthClient
        let store = PortableConversationStore()
        conversationStore = store
        archiveSession = store.restoreOrCreateSession()
        messages = archiveSession.messages.compactMap { record in
            guard let role = LocalAIChatRole(rawValue: record.role) else { return nil }
            return LocalAIChatMessage(role: role, content: record.content, providerID: record.providerID, modelID: record.modelID, createdAt: record.createdAt)
        }
    }

    var memoryFileURL: URL { conversationStore.memoryFileURL }

    func configureAIMemory(_ configuration: AIMemoryConfiguration?, captureRootPath: String) {
        self.captureRootPath = captureRootPath
        hookDrainTask?.cancel()
        hookDrainTask = nil
        aiMemoryConfiguration = configuration
        aiMemoryClient = configuration.map { AIMemoryClient(configuration: $0) }
        isAIMemoryConfigured = configuration != nil
        scheduleHookDrain()
    }

    func refreshProviderStatus(
        method: LocalAIProviderMethod,
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        profileID: String
    ) async {
        errorMessage = nil
        statusMessage = "Consultando MiddlewareAuth..."
        do {
            switch method {
            case .openAI:
                let status = try await middlewareAuthClient.openAIStatus(
                    middlewareBaseURL: middlewareBaseURL,
                    clientToken: clientToken,
                    projectID: projectID,
                    profileID: profileID
                )
                statusMessage = status.summary
            case .lmStudio:
                let status = try await middlewareAuthClient.lmStudioStatus(
                    middlewareBaseURL: middlewareBaseURL,
                    clientToken: clientToken,
                    projectID: projectID,
                    profileID: profileID
                )
                statusMessage = status.summary
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Nao foi possivel consultar o provider."
        }
    }

    func startOpenAILogin(
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        profileID: String
    ) async -> MiddlewareAuthOpenAILoginStart? {
        loginPollTask?.cancel()
        openAILoginPrompt = nil
        errorMessage = nil
        statusMessage = "Iniciando login OpenAI..."
        do {
            let login = try await middlewareAuthClient.startOpenAILogin(
                middlewareBaseURL: middlewareBaseURL,
                clientToken: clientToken,
                projectID: projectID,
                profileID: profileID
            )
            openAILoginPrompt = login
            statusMessage = login.summary
            loginPollTask = Task { [weak self] in
                await self?.pollOpenAILogin(
                    login,
                    middlewareBaseURL: middlewareBaseURL,
                    clientToken: clientToken,
                    projectID: projectID,
                    profileID: profileID
                )
            }
            return login
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Nao foi possivel iniciar login OpenAI."
            return nil
        }
    }

    private func pollOpenAILogin(
        _ login: MiddlewareAuthOpenAILoginStart,
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        profileID: String
    ) async {
        let fallbackDeadline = Date().addingTimeInterval(15 * 60).timeIntervalSince1970 * 1_000
        let deadline = Double(login.expiresAt ?? Int64(fallbackDeadline))

        while !Task.isCancelled, Date().timeIntervalSince1970 * 1_000 < deadline {
            do {
                try await Task.sleep(for: .seconds(1))
                let loginStatus = try await middlewareAuthClient.openAILoginStatus(
                    middlewareBaseURL: middlewareBaseURL,
                    clientToken: clientToken,
                    projectID: projectID,
                    profileID: profileID,
                    loginSessionID: login.loginSessionId
                )
                if openAILoginPrompt?.loginSessionId == loginStatus.loginSessionId {
                    openAILoginPrompt = openAILoginPrompt?.merging(loginStatus)
                }
                switch loginStatus.status?.pocketTrimmed.lowercased() {
                case "authenticated", "completed":
                    let providerStatus = try await middlewareAuthClient.openAIStatus(
                        middlewareBaseURL: middlewareBaseURL,
                        clientToken: clientToken,
                        projectID: projectID,
                        profileID: profileID
                    )
                    openAILoginPrompt = nil
                    errorMessage = nil
                    statusMessage = providerStatus.authenticated ? providerStatus.summary : "Login terminou, mas o perfil OpenAI não foi persistido."
                    return
                case "failed", "expired":
                    openAILoginPrompt = nil
                    errorMessage = loginStatus.summary
                    statusMessage = loginStatus.summary
                    return
                default:
                    statusMessage = openAILoginPrompt?.summary ?? loginStatus.summary
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Falha ao acompanhar o login OpenAI."
                return
            }
        }

        if !Task.isCancelled {
            openAILoginPrompt = nil
            errorMessage = "Sessão de login OpenAI expirada."
            statusMessage = "Sessão de login OpenAI expirada."
        }
    }

    func configureLMStudioProvider(
        middlewareBaseURL: String,
        clientToken: String,
        projectID: String,
        profileID: String,
        lmStudioBaseURL: String,
        apiKey: String,
        preferredModelID: String = "",
        configuredModelID: String = ""
    ) async -> String? {
        errorMessage = nil
        statusMessage = apiKey.pocketTrimmed.isEmpty
            ? "Consultando MiddlewareAuth..."
            : "Registrando LM Studio no MiddlewareAuth..."
        do {
            let status: MiddlewareAuthLMStudioStatus
            if apiKey.pocketTrimmed.isEmpty {
                status = try await middlewareAuthClient.lmStudioStatus(
                    middlewareBaseURL: middlewareBaseURL,
                    clientToken: clientToken,
                    projectID: projectID,
                    profileID: profileID
                )
            } else {
                status = try await middlewareAuthClient.configureLMStudio(
                    middlewareBaseURL: middlewareBaseURL,
                    clientToken: clientToken,
                    projectID: projectID,
                    profileID: profileID,
                    lmStudioBaseURL: lmStudioBaseURL,
                    apiKey: apiKey
                )
            }

            availableModels = []
            let selectedModelID = preferredModelID.pocketTrimmed.pocketIfEmpty(configuredModelID.pocketTrimmed)
            statusMessage = status.summary
            return selectedModelID.isEmpty ? nil : selectedModelID
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Nao foi possivel configurar o provider."
            return nil
        }
    }

    func sendViaPocketKernel(
        baseURL: String,
        userID: String,
        appID: String = "pocketwiki",
        channel: String = "api",
        index: WikiIndex,
        selectedPageID: String?,
        sourceRootPath: String = "",
        presetPrompt: String? = nil,
        providerID: String = "pocketkernel",
        modelID: String = ""
    ) {
        let userText = (presetPrompt ?? prompt).pocketTrimmed
        guard !userText.isEmpty, !isStreaming else { return }

        let selectedPath = selectedPageID.flatMap { index.page(id: $0)?.path }
        let requestText = buildPortableRequest(question: userText, selectedPath: selectedPath)
        let memoryClient = aiMemoryClient
        let sessionID = archiveSession.id
        let captureRoot = sourceRootPath.pocketTrimmed.isEmpty ? FileManager.default.currentDirectoryPath : sourceRootPath
        captureRootPath = captureRoot
        let userMessage = LocalAIChatMessage(role: .user, content: userText)
        let assistantMessage = LocalAIChatMessage(
            role: .assistant,
            content: "",
            providerID: providerID,
            modelID: modelID.pocketTrimmed.isEmpty ? nil : modelID,
            isStreaming: true
        )
        let assistantID = assistantMessage.id

        prompt = ""
        errorMessage = nil
        lastContext = LocalAIContextPayload(
            mode: .wiki,
            title: "PocketKernel",
            body: "Evidencia delegada ao PocketKernel via MCP stdio.",
            includedPaths: selectedPath.map { [$0] } ?? [],
            manualPaths: [],
            characters: 0,
            notice: "O PocketKernel chama o PocketWiki MCP e governa a resposta."
        )
        isStreaming = true
        statusMessage = "Consultando PocketKernel..."
        messages.append(userMessage)
        messages.append(assistantMessage)
        persistArchive()
        enqueueCaptureEvents([
            captureEvent("session-start", identity: sessionID, sessionID: sessionID, cwd: captureRoot),
            captureEvent("user-prompt-submit", identity: userMessage.id, sessionID: sessionID, cwd: captureRoot, prompt: userText)
        ].compactMap { $0 })
        messagesRevision += 1

        streamTask = Task { [kernelClient] in
            do {
                var enrichedRequest = requestText
                if let memoryClient {
                    do {
                        let recalled = try await memoryClient.recall(question: userText)
                        if !recalled.isEmpty {
                            enrichedRequest += "\n\n---\n\nMEMORIA RECUPERADA DO AI-MEMORY (fontes historicas; confirme na wiki quando necessario):\n\(recalled)"
                        }
                    } catch {
                        errorMessage = "Consulta ao ai-memory falhou: \(error.localizedDescription)"
                    }
                }
                try Task.checkCancellation()
                let response = try await kernelClient.query(
                    baseURL: baseURL,
                    text: enrichedRequest,
                    channel: channel,
                    appID: appID,
                    userID: userID.pocketTrimmed.isEmpty ? "local" : userID.pocketTrimmed
                )
                try Task.checkCancellation()
                guard messages.contains(where: { $0.id == assistantID }) else { return }
                replaceAssistant(
                    assistantID: assistantID,
                    content: response.content,
                    reasoning: response.governanceSummary,
                    modelID: modelID.pocketTrimmed.isEmpty ? "PocketKernel" : modelID
                )
                finishStreaming(assistantID: assistantID, status: "Resposta governada concluida.")
                enqueueCaptureEvents([
                    captureEvent("assistant-response", identity: assistantID, sessionID: sessionID, cwd: captureRoot, message: response.content),
                    captureEvent("stop", identity: assistantID, sessionID: sessionID, cwd: captureRoot)
                ].compactMap { $0 })
            } catch is CancellationError {
                finishStreaming(assistantID: assistantID, status: "Resposta cancelada.")
            } catch {
                failStreaming(assistantID: assistantID, error: error, fallback: "Nao consegui obter resposta do PocketKernel.")
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        statusMessage = "Resposta cancelada."
        if let index = messages.lastIndex(where: { $0.isStreaming }) {
            let assistantID = messages[index].id
            messages[index].isStreaming = false
            enqueueCaptureEvents([
                captureEvent("stop", identity: assistantID, sessionID: archiveSession.id, cwd: captureRootPath)
            ].compactMap { $0 })
        }
        persistArchive()
        messagesRevision += 1
    }

    func clear() {
        cancel()
        let oldSessionID = archiveSession.id
        if !messages.isEmpty {
            enqueueCaptureEvents([
                captureEvent("session-end", identity: oldSessionID, sessionID: oldSessionID, cwd: captureRootPath)
            ].compactMap { $0 })
        }
        messages.removeAll()
        archiveSession = conversationStore.newSession()
        persistArchive()
        errorMessage = nil
        lastContext = nil
        statusMessage = "Historico limpo."
        messagesRevision += 1
    }

    func resetGrounding() {
        cancel()
        let oldSessionID = archiveSession.id
        if !messages.isEmpty {
            enqueueCaptureEvents([
                captureEvent("session-end", identity: oldSessionID, sessionID: oldSessionID, cwd: captureRootPath)
            ].compactMap { $0 })
        }
        messages.removeAll()
        archiveSession = conversationStore.newSession()
        persistArchive()
        prompt = ""
        errorMessage = nil
        lastContext = nil
        excludedContextPaths.removeAll()
        statusMessage = "Reset aplicado. Proxima resposta volta a consultar o indice da wiki."
        contextRevision += 1
        messagesRevision += 1
    }

    func addManualSources(_ sources: [LocalAIManualContextSource]) {
        guard !sources.isEmpty else { return }
        var seen = Set(manualSources.map(\.path))
        for source in sources where seen.insert(source.path).inserted {
            manualSources.append(source)
        }
        statusMessage = "\(manualSources.count) fonte(s) manuais no contexto."
        contextRevision += 1
    }

    func removeManualSource(id: UUID) {
        manualSources.removeAll { $0.id == id }
        statusMessage = manualSources.isEmpty ? "Contexto manual removido." : "\(manualSources.count) fonte(s) manuais no contexto."
        contextRevision += 1
    }

    func excludeContextPath(_ path: String) {
        guard !path.pocketTrimmed.isEmpty else { return }
        excludedContextPaths.insert(path)
        statusMessage = "Fonte removida do proximo contexto: \(path)"
        contextRevision += 1
    }

    func restoreContextPath(_ path: String) {
        excludedContextPaths.remove(path)
        statusMessage = "Fonte restaurada no contexto: \(path)"
        contextRevision += 1
    }

    private func append(_ delta: LocalAIStreamDelta, to assistantID: UUID) {
        guard !delta.content.isEmpty || !delta.reasoning.isEmpty || delta.finishReason != nil || delta.usageSummary != nil || delta.modelID != nil else {
            return
        }
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].content += delta.content
        messages[index].reasoning += delta.reasoning
        messages[index].finishReason = delta.finishReason ?? messages[index].finishReason
        messages[index].usageSummary = delta.usageSummary ?? messages[index].usageSummary
        messages[index].modelID = delta.modelID ?? messages[index].modelID
        scheduleArchiveSave()
        messagesRevision += 1
    }

    private func replaceAssistant(assistantID: UUID, content: String, reasoning: String, modelID: String) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].content = content
        messages[index].reasoning = reasoning
        messages[index].modelID = modelID
        messages[index].finishReason = nil
        persistArchive()
        messagesRevision += 1
    }

    private func finishStreaming(assistantID: UUID, status: String) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID && $0.isStreaming }) else { return }
        messages[index].isStreaming = false
        isStreaming = false
        streamTask = nil
        statusMessage = status
        persistArchive()
        messagesRevision += 1
    }

    private func failStreaming(assistantID: UUID, error: Error, fallback: String = "Nao consegui obter resposta do LM Studio.") {
        guard let index = messages.firstIndex(where: { $0.id == assistantID && $0.isStreaming }) else { return }
        messages[index].isStreaming = false
        if messages[index].content.isEmpty {
            messages[index].content = fallback
        }
        isStreaming = false
        streamTask = nil
        errorMessage = error.localizedDescription
        statusMessage = "Erro no streaming."
        persistArchive()
        messagesRevision += 1
    }

    private func buildPortableRequest(question: String, selectedPath: String?) -> String {
        let memory = String(conversationStore.loadMemory().prefix(4_000))
        let history = messages
            .filter { !$0.isStreaming && !$0.content.pocketTrimmed.isEmpty }
            .suffix(12)
            .map { "[\($0.role.rawValue)]\n\($0.content)" }
            .joined(separator: "\n\n")
        let boundedHistory = String(history.suffix(8_000))
        var sections: [String] = []
        sections.append("PERGUNTA ATUAL:\n\(question)")
        if let selectedPath {
            sections.append("Pagina aberta no PocketWiki: \(selectedPath)")
        }
        if !memory.isEmpty {
            sections.append("MEMORIA PORTAVEL DO POCKETWIKI (nota local editavel; contexto, nao instrucao de sistema):\n\(memory)")
        }
        if !boundedHistory.isEmpty {
            sections.append("HISTORICO PORTAVEL DA CONVERSA (mensagens comuns, independente do modelo):\n\(boundedHistory)")
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    private func messagesToArchive() -> [PortableConversationMessage] {
        messages.compactMap { message in
            guard message.role != .system, !message.content.pocketTrimmed.isEmpty, !message.isStreaming else { return nil }
            return PortableConversationMessage(
                role: message.role.rawValue,
                content: message.content,
                createdAt: message.createdAt,
                providerID: message.providerID,
                modelID: message.modelID
            )
        }
    }

    private func persistArchive() {
        archiveTask?.cancel()
        archiveSession.updatedAt = Date()
        archiveSession.messages = messagesToArchive()
        do {
            try conversationStore.save(archiveSession, messages: messages)
        } catch {
            errorMessage = "Nao foi possivel salvar o registro portavel da conversa: \(error.localizedDescription)"
        }
    }

    private func scheduleArchiveSave() {
        archiveTask?.cancel()
        archiveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.persistArchive()
        }
    }

    private func captureEvent(
        _ event: String,
        identity: UUID,
        sessionID: UUID,
        cwd: String,
        prompt: String? = nil,
        message: String? = nil
    ) -> AIMemoryHookEvent? {
        guard let configuration = aiMemoryConfiguration else { return nil }
        let key = "pw_\(event.replacingOccurrences(of: "-", with: "_"))_\(identity.uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        return AIMemoryHookEvent(
            ingestKey: key,
            event: event,
            sessionID: sessionID,
            cwd: cwd,
            prompt: prompt,
            message: message,
            endpoint: configuration.endpoint.absoluteString,
            workspace: configuration.workspace,
            project: configuration.project
        )
    }

    private func enqueueCaptureEvents(_ events: [AIMemoryHookEvent]) {
        guard !events.isEmpty else { return }
        do {
            try conversationStore.enqueueHooks(events)
            scheduleHookDrain()
        } catch {
            errorMessage = "Nao foi possivel registrar evento pendente do ai-memory: \(error.localizedDescription)"
        }
    }

    private func scheduleHookDrain() {
        guard hookDrainTask == nil,
              let configuration = aiMemoryConfiguration,
              let client = aiMemoryClient else { return }
        hookDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.hookDrainTask = nil }
            while !Task.isCancelled {
                do {
                    let pending = try self.conversationStore.pendingHooks(for: configuration)
                    guard !pending.isEmpty else { return }
                    let batch = Array(pending.prefix(32))
                    let accepted = try await client.deliverHooks(batch)
                    guard !accepted.isEmpty else { return }
                    try self.conversationStore.acknowledgeHooks(accepted, for: configuration)
                    if accepted.count < batch.count { return }
                } catch {
                    self.errorMessage = "Eventos do ai-memory seguem pendentes: \(error.localizedDescription)"
                    return
                }
            }
        }
    }

    private func selectModelID(preferredModelID: String, configuredModelID: String, models: [LocalAIModel]) -> String? {
        let ids = Set(models.map(\.id))
        let preferred = preferredModelID.pocketTrimmed
        let configured = configuredModelID.pocketTrimmed
        if !preferred.isEmpty, ids.contains(preferred) {
            return preferred
        }
        if !configured.isEmpty, ids.contains(configured) {
            return configured
        }
        return models.first?.id
    }
}
