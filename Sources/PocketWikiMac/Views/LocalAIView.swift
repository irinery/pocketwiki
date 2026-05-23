import SwiftUI

struct LocalAIView: View {
    @Bindable var store: WikiAppStore

    @AppStorage("PocketWikiMac.localAI.baseURL") private var baseURL = LocalAIEndpointPolicy.defaultBaseURL
    @AppStorage("PocketWikiMac.localAI.modelID") private var modelID = ""
    @AppStorage("PocketWikiMac.localAI.contextScope") private var contextScopeRaw = LocalAIContextScope.automatic.rawValue
    @AppStorage("PocketWikiMac.localAI.maxContextCharacters") private var maxContextCharacters = 12_000
    @AppStorage("PocketWikiMac.localAI.temperature") private var temperature = 0.2
    @SceneStorage("PocketWikiMac.localAI.sidePanel") private var sidePanelRaw = LocalAISidePanel.llm.rawValue

    @State private var chat = LocalAIChatSession()
    @State private var apiKey = ""
    @State private var runtimeAPIKey = ""
    @State private var configuredModelID = ""
    @State private var runtimeTokenLoaded = false

    private var sidePanel: Binding<LocalAISidePanel?> {
        Binding(
            get: { LocalAISidePanel(rawValue: sidePanelRaw) },
            set: { sidePanelRaw = $0?.rawValue ?? "" }
        )
    }

    private var contextScope: LocalAIContextScope {
        LocalAIContextScope(rawValue: contextScopeRaw) ?? .automatic
    }

    private var effectiveAPIKey: String {
        let manual = apiKey.pocketTrimmed
        return manual.isEmpty ? runtimeAPIKey : manual
    }

    private var connectionLabel: String {
        chat.availableModels.isEmpty ? "desconectado" : "LM Studio conectado"
    }

    var body: some View {
        GeometryReader { proxy in
            let layoutMode = LocalAIWorkspaceLayoutMode(width: proxy.size.width)
            let activePanel = sidePanel.wrappedValue

            LocalAIWorkspaceShell(
                mode: layoutMode,
                isSidePanelOpen: activePanel != nil
            ) {
                LocalAIHeroView()
            } chat: {
                LocalAIChatPanel(
                    chat: chat,
                    connectionLabel: connectionLabel,
                    contextScope: contextScope,
                    canSend: canSendPrompt,
                    onSend: sendPrompt,
                    onCancel: chat.cancel,
                    onReset: resetGroundedChat,
                    onClear: chat.clear
                )
            } sideRail: {
                LocalAISideRail(
                    selection: sidePanel,
                    orientation: layoutMode == .regular ? .vertical : .horizontal
                )
            } sidePanel: {
                if let activePanel {
                    LocalAISidePanelContent(
                        panel: activePanel,
                        baseURL: $baseURL,
                        modelID: $modelID,
                        apiKey: $apiKey,
                        availableModels: chat.availableModels,
                        runtimeTokenLoaded: runtimeTokenLoaded,
                        isStreaming: chat.isStreaming,
                        contextSummary: contextSummaryText,
                        contextSourceCount: chat.lastContext?.includedPaths.count ?? 0,
                        onRefreshModels: refreshModelSelection,
                        onClose: { sidePanel.wrappedValue = nil }
                    )
                }
            }
        }
        .task {
            await bootstrapLocalAI()
        }
    }

    private var canSendPrompt: Bool {
        !chat.prompt.pocketTrimmed.isEmpty && !modelID.pocketTrimmed.isEmpty
    }

    private var contextSummaryText: String {
        guard let context = chat.lastContext else {
            return "sem contexto carregado"
        }

        var lines: [String] = []
        if let notice = context.notice, !notice.isEmpty {
            lines.append(notice)
        }
        if context.includedPaths.isEmpty {
            lines.append("sem paginas consultadas")
        } else {
            lines.append(contentsOf: context.includedPaths)
        }
        return lines.joined(separator: "\n")
    }

    private func sendPrompt() {
        guard canSendPrompt else { return }
        normalizeBaseURLPreference()
        chat.send(
            baseURL: baseURL,
            apiKey: effectiveAPIKey,
            modelID: modelID,
            temperature: temperature,
            contextScope: contextScope,
            maxContextCharacters: maxContextCharacters,
            index: store.index,
            selectedPageID: store.selectedPageID
        )
    }

    private func resetGroundedChat() {
        chat.resetGrounding()
        contextScopeRaw = LocalAIContextScope.automatic.rawValue
        temperature = 0.2
        sidePanel.wrappedValue = .context
    }

    @MainActor
    private func bootstrapLocalAI() async {
        let runtime = LocalAIRuntimeConfigurationLoader.load()
        configuredModelID = runtime.modelID
        runtimeAPIKey = runtime.apiKey
        runtimeTokenLoaded = runtime.hasToken

        let runtimeBaseURL = runtime.baseURL.pocketTrimmed
        if !runtimeBaseURL.isEmpty, baseURL.pocketTrimmed.isEmpty || baseURL == LocalAIEndpointPolicy.defaultBaseURL {
            baseURL = runtimeBaseURL
        }
        if modelID.pocketTrimmed.isEmpty, !runtime.modelID.pocketTrimmed.isEmpty {
            modelID = runtime.modelID
        }
        normalizeBaseURLPreference()

        if chat.availableModels.isEmpty {
            await refreshModelSelection()
        }
    }

    @MainActor
    private func refreshModelSelection() async {
        normalizeBaseURLPreference()
        let selected = await chat.refreshModels(
            baseURL: baseURL,
            apiKey: effectiveAPIKey,
            preferredModelID: modelID,
            configuredModelID: configuredModelID
        )
        if let selected {
            modelID = selected
        } else if modelID.pocketTrimmed.isEmpty, !configuredModelID.pocketTrimmed.isEmpty {
            modelID = configuredModelID
        }
    }

    private func normalizeBaseURLPreference() {
        guard let normalized = try? LocalAIEndpointPolicy.normalizedBaseURL(baseURL) else { return }
        let value = normalized.absoluteString
        if baseURL != value {
            baseURL = value
        }
    }
}
