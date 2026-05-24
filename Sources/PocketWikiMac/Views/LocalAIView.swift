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

    private var effectiveBaseURL: String {
        store.remoteAIProxyBaseURL ?? baseURL
    }

    private var connectionLabel: String {
        if store.remoteAIProxyBaseURL != nil, !chat.availableModels.isEmpty {
            return "IA via servidor remoto"
        }
        return chat.availableModels.isEmpty ? "desconectado" : "LM Studio conectado"
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
                    index: store.index,
                    connectionLabel: connectionLabel,
                    contextScope: contextScope,
                    canSend: canSendPrompt,
                    onOpenPage: { store.selectPage($0, tab: .reader) },
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
                        contextNotice: chat.lastContext?.notice,
                        autoContextPaths: autoContextPaths,
                        manualSources: chat.manualSources,
                        excludedContextPaths: chat.excludedContextPaths,
                        contextSourceCount: activeContextSourceCount,
                        onRefreshModels: refreshModelSelection,
                        onAddContextFiles: addContextFiles,
                        onRemoveManualSource: chat.removeManualSource,
                        onExcludeContextPath: chat.excludeContextPath,
                        onRestoreContextPath: chat.restoreContextPath,
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

    private var autoContextPaths: [String] {
        guard let context = chat.lastContext else { return [] }
        let manual = Set(context.manualPaths)
        return context.includedPaths.filter { !manual.contains($0) }
    }

    private var activeContextSourceCount: Int {
        autoContextPaths.filter { !chat.excludedContextPaths.contains($0) }.count + chat.manualSources.count
    }

    private func sendPrompt() {
        guard canSendPrompt else { return }
        normalizeBaseURLPreference()
        chat.send(
            baseURL: effectiveBaseURL,
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
    private func addContextFiles() {
        do {
            let sources = try LocalAIContextFilePicker.pickFiles()
            chat.addManualSources(sources)
            if !sources.isEmpty {
                sidePanel.wrappedValue = .context
            }
        } catch {
            chat.errorMessage = error.localizedDescription
        }
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
            baseURL: effectiveBaseURL,
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
        guard store.remoteAIProxyBaseURL == nil else { return }
        guard let normalized = try? LocalAIEndpointPolicy.normalizedBaseURL(baseURL) else { return }
        let value = normalized.absoluteString
        if baseURL != value {
            baseURL = value
        }
    }
}
