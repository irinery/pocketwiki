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

    private let client: LMStudioClient
    private var streamTask: Task<Void, Never>?

    init(client: LMStudioClient = LMStudioClient()) {
        self.client = client
    }

    func refreshModels(baseURL: String, apiKey: String?, preferredModelID: String = "", configuredModelID: String = "") async -> String? {
        errorMessage = nil
        statusMessage = "Buscando modelos no LM Studio..."
        do {
            availableModels = try await client.listModels(baseURL: baseURL, apiKey: apiKey)
            let selectedModelID = selectModelID(
                preferredModelID: preferredModelID,
                configuredModelID: configuredModelID,
                models: availableModels
            )
            statusMessage = availableModels.isEmpty
                ? "Nenhum modelo retornado. Confira se o LM Studio esta com modelo carregado."
                : "\(availableModels.count) modelo(s) encontrado(s): \(selectedModelID ?? availableModels[0].id)."
            return selectedModelID
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Nao foi possivel listar modelos."
            return nil
        }
    }

    func send(
        baseURL: String,
        apiKey: String?,
        modelID: String,
        temperature: Double,
        contextScope: LocalAIContextScope,
        maxContextCharacters: Int,
        index: WikiIndex,
        selectedPageID: String?,
        presetPrompt: String? = nil
    ) {
        let userText = (presetPrompt ?? prompt).pocketTrimmed
        guard !userText.isEmpty, !isStreaming else { return }

        let context = LocalAIContextBuilder.build(
            index: index,
            selectedPageID: selectedPageID,
            scope: contextScope,
            maxCharacters: maxContextCharacters,
            question: userText,
            manualSources: manualSources,
            excludedPaths: excludedContextPaths
        )
        let userMessage = LocalAIChatMessage(role: .user, content: userText)
        let assistantMessage = LocalAIChatMessage(role: .assistant, content: "", modelID: modelID, isStreaming: true)
        let requestMessages = [userMessage]
        let assistantID = assistantMessage.id

        prompt = ""
        errorMessage = nil
        lastContext = context
        isStreaming = true
        statusMessage = context.mode == .wiki
            ? "Consulta seletiva: \(context.includedPaths.count) fonte(s), \(context.characters) caracteres."
            : "Conversa geral sem contexto pesado da wiki."
        messages.append(userMessage)
        messages.append(assistantMessage)
        messagesRevision += 1

        streamTask = Task { [client] in
            do {
                let stream = try client.streamChat(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    modelID: modelID,
                    temperature: temperature,
                    context: context,
                    messages: requestMessages
                )

                var pending = LocalAIStreamDelta()
                var lastFlush = Date()
                for try await delta in stream {
                    pending.content += delta.content
                    pending.reasoning += delta.reasoning
                    pending.finishReason = delta.finishReason ?? pending.finishReason
                    pending.usageSummary = delta.usageSummary ?? pending.usageSummary
                    pending.modelID = delta.modelID ?? pending.modelID

                    if Date().timeIntervalSince(lastFlush) >= 0.08 {
                        append(pending, to: assistantID)
                        pending = LocalAIStreamDelta()
                        lastFlush = Date()
                    }
                }
                append(pending, to: assistantID)
                finishStreaming(assistantID: assistantID, status: "Resposta concluida.")
            } catch is CancellationError {
                finishStreaming(assistantID: assistantID, status: "Resposta cancelada.")
            } catch {
                failStreaming(assistantID: assistantID, error: error)
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

    private func finishStreaming(assistantID: UUID, status: String) {
        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].isStreaming = false
        }
        isStreaming = false
        streamTask = nil
        statusMessage = status
        messagesRevision += 1
    }

    private func failStreaming(assistantID: UUID, error: Error) {
        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].isStreaming = false
            if messages[index].content.isEmpty {
                messages[index].content = "Nao consegui obter resposta do LM Studio."
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
