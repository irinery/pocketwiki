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
    private(set) var openAILoginPrompt: MiddlewareAuthOpenAILoginStart?

    private let kernelClient: PocketKernelClient
    private let middlewareAuthClient: MiddlewareAuthClient
    private var streamTask: Task<Void, Never>?
    private var loginPollTask: Task<Void, Never>?

    init(
        kernelClient: PocketKernelClient = PocketKernelClient(),
        middlewareAuthClient: MiddlewareAuthClient = MiddlewareAuthClient()
    ) {
        self.kernelClient = kernelClient
        self.middlewareAuthClient = middlewareAuthClient
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
        presetPrompt: String? = nil
    ) {
        let userText = (presetPrompt ?? prompt).pocketTrimmed
        guard !userText.isEmpty, !isStreaming else { return }

        let selectedPath = selectedPageID.flatMap { index.page(id: $0)?.path }
        let requestText = selectedPath.map { "Pagina aberta no PocketWiki: \($0)\n\nPergunta:\n\(userText)" } ?? userText
        let userMessage = LocalAIChatMessage(role: .user, content: userText)
        let assistantMessage = LocalAIChatMessage(role: .assistant, content: "", modelID: "PocketKernel", isStreaming: true)
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
        messagesRevision += 1

        streamTask = Task { [kernelClient] in
            do {
                let response = try await kernelClient.query(
                    baseURL: baseURL,
                    text: requestText,
                    channel: channel,
                    appID: appID,
                    userID: userID.pocketTrimmed.isEmpty ? "local" : userID.pocketTrimmed
                )
                replaceAssistant(
                    assistantID: assistantID,
                    content: response.content,
                    reasoning: response.governanceSummary,
                    modelID: "PocketKernel"
                )
                finishStreaming(assistantID: assistantID, status: "Resposta governada concluida.")
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
            messages[index].isStreaming = false
        }
        messagesRevision += 1
    }

    func clear() {
        cancel()
        messages.removeAll()
        errorMessage = nil
        lastContext = nil
        statusMessage = "Historico limpo."
        messagesRevision += 1
    }

    func resetGrounding() {
        cancel()
        messages.removeAll()
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
        messagesRevision += 1
    }

    private func replaceAssistant(assistantID: UUID, content: String, reasoning: String, modelID: String) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].content = content
        messages[index].reasoning = reasoning
        messages[index].modelID = modelID
        messages[index].finishReason = nil
        messagesRevision += 1
    }

    private func finishStreaming(assistantID: UUID, status: String) {
        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].isStreaming = false
        }
        isStreaming = false
        streamTask = nil
        statusMessage = status
        messagesRevision += 1
    }

    private func failStreaming(assistantID: UUID, error: Error, fallback: String = "Nao consegui obter resposta do LM Studio.") {
        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].isStreaming = false
            if messages[index].content.isEmpty {
                messages[index].content = fallback
            }
        }
        isStreaming = false
        streamTask = nil
        errorMessage = error.localizedDescription
        statusMessage = "Erro no streaming."
        messagesRevision += 1
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
