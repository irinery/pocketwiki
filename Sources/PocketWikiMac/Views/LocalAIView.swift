import AppKit
import SwiftUI

struct LocalAIView: View {
    @Bindable var store: WikiAppStore

    @AppStorage("PocketWikiMac.localAI.providerMethod") private var providerMethodRaw = LocalAIProviderMethod.openAI.rawValue
    @AppStorage("PocketWikiMac.localAI.reasoningEffort") private var reasoningEffortRaw = LocalAIReasoningEffort.medium.rawValue
    @AppStorage("PocketWikiMac.localAI.baseURL") private var baseURL = "http://127.0.0.1:1234"
    @AppStorage("PocketWikiMac.localAI.kernelBaseURL") private var kernelBaseURL = PocketKernelEndpointPolicy.defaultBaseURL
    @AppStorage("PocketWikiMac.localAI.middlewareBaseURL") private var middlewareAuthBaseURL = MiddlewareAuthEndpointPolicy.defaultBaseURL
    @AppStorage("PocketWikiMac.localAI.middlewareProjectID") private var middlewareAuthProjectID = "acme"
    @AppStorage("PocketWikiMac.localAI.middlewareProfileID") private var middlewareAuthProfileID = "default"
    @AppStorage("PocketWikiMac.localAI.openAIModelID") private var openAIModelID = "gpt-5.5"
    @AppStorage("PocketWikiMac.localAI.lmStudioModelID") private var lmStudioModelID = ""
    @AppStorage("PocketWikiMac.localAI.contextScope") private var contextScopeRaw = LocalAIContextScope.automatic.rawValue
    @AppStorage("PocketWikiMac.localAI.maxContextCharacters") private var maxContextCharacters = 12_000
    @AppStorage("PocketWikiMac.localAI.temperature") private var temperature = 0.2
    @SceneStorage("PocketWikiMac.localAI.sidePanel") private var sidePanelRaw = LocalAISidePanel.llm.rawValue
    @State private var isAdvancedSettingsPresented = false

    private var sidePanel: Binding<LocalAISidePanel?> {
        Binding(
            get: { LocalAISidePanel(rawValue: sidePanelRaw) },
            set: { sidePanelRaw = $0?.rawValue ?? "" }
        )
    }

    private var contextScope: LocalAIContextScope {
        LocalAIContextScope(rawValue: contextScopeRaw) ?? .automatic
    }

    private var chat: LocalAIChatSession {
        store.localAIChatSession
    }

    private var pendingLMStudioAPIKey: String {
        store.localAIAPIKey.pocketTrimmed
    }

    private var effectiveKernelBaseURL: String {
        store.remoteKernelQueryURL ?? kernelBaseURL
    }

    private var connectionLabel: String {
        store.remoteKernelQueryURL == nil ? "PocketKernel Harness" : "PocketKernel remoto"
    }

    private var providerMethod: LocalAIProviderMethod {
        LocalAIProviderMethod.value(for: providerMethodRaw)
    }

    private var selectedModelID: String {
        providerMethod == .openAI ? openAIModelID : lmStudioModelID
    }

    private var selectedModelIDBinding: Binding<String> {
        Binding(
            get: { selectedModelID },
            set: { value in
                if providerMethod == .openAI {
                    openAIModelID = value
                } else {
                    lmStudioModelID = value
                }
            }
        )
    }

    private var providerStatusText: String {
        if let error = chat.errorMessage, !error.pocketTrimmed.isEmpty {
            return error
        }
        let status = chat.statusMessage.pocketTrimmed
        if status.isEmpty || status == "Pronto para conversar com a IA local." {
            return providerMethod.statusFallback
        }
        return status
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
                        providerMethodRaw: $providerMethodRaw,
                        reasoningEffortRaw: $reasoningEffortRaw,
                        kernelBaseURL: $kernelBaseURL,
                        middlewareAuthBaseURL: $middlewareAuthBaseURL,
                        middlewareAuthProjectID: $middlewareAuthProjectID,
                        middlewareAuthProfileID: $middlewareAuthProfileID,
                        baseURL: $baseURL,
                        modelID: selectedModelIDBinding,
                        middlewareAuthToken: $store.middlewareAuthClientToken,
                        apiKey: $store.localAIAPIKey,
                        availableModels: chat.availableModels,
                        middlewareRuntimeTokenLoaded: store.middlewareAuthRuntimeTokenLoaded,
                        runtimeTokenLoaded: store.localAIRuntimeTokenLoaded,
                        isStreaming: chat.isStreaming,
                        providerStatusText: providerStatusText,
                        contextNotice: chat.lastContext?.notice,
                        autoContextPaths: autoContextPaths,
                        manualSources: chat.manualSources,
                        excludedContextPaths: chat.excludedContextPaths,
                        contextSourceCount: activeContextSourceCount,
                        onPrimaryProviderAction: { await runPrimaryProviderAction() },
                        onRefreshModels: { await refreshProviderStatus() },
                        onOpenAdvancedSettings: { isAdvancedSettingsPresented = true },
                        onAddContextFiles: addContextFiles,
                        onRemoveManualSource: chat.removeManualSource,
                        onExcludeContextPath: chat.excludeContextPath,
                        onRestoreContextPath: chat.restoreContextPath,
                        onClose: { sidePanel.wrappedValue = nil }
                    )
                }
            }
        }
        .sheet(isPresented: $isAdvancedSettingsPresented) {
            LocalAIAdvancedSettingsSheet(
                providerMethodRaw: $providerMethodRaw,
                reasoningEffortRaw: $reasoningEffortRaw,
                kernelBaseURL: $kernelBaseURL,
                middlewareAuthBaseURL: $middlewareAuthBaseURL,
                middlewareAuthProjectID: $middlewareAuthProjectID,
                middlewareAuthProfileID: $middlewareAuthProfileID,
                baseURL: $baseURL,
                modelID: selectedModelIDBinding,
                middlewareAuthToken: $store.middlewareAuthClientToken,
                apiKey: $store.localAIAPIKey,
                middlewareRuntimeTokenLoaded: store.middlewareAuthRuntimeTokenLoaded,
                runtimeTokenLoaded: store.localAIRuntimeTokenLoaded,
                middlewareAddonStatus: store.middlewareAuthAddon.status,
                middlewareAddonAccessVerified: store.middlewareAuthAddon.accessVerified,
                pocketKernelAddonStatus: store.pocketKernelAddon.status,
                pocketKernelAddonReady: store.pocketKernelAddon.healthAvailable && store.pocketKernelAddon.providerAvailable,
                onRestartMiddlewareAddon: {
                    await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
                },
                onRestartPocketKernelAddon: {
                    await store.ensurePocketKernelAddon(baseURL: kernelBaseURL)
                }
            )
        }
        .task {
            await bootstrapLocalAI()
        }
    }

    private var canSendPrompt: Bool {
        guard !chat.prompt.pocketTrimmed.isEmpty else { return false }
        return !effectiveKernelBaseURL.pocketTrimmed.isEmpty
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
        Task {
            if providerMethod == .lmStudio, !pendingLMStudioAPIKey.isEmpty {
                await configureProvider(silent: true)
                if chat.errorMessage != nil { return }
            }
            await syncPocketKernelProvider()
            guard store.pocketKernelAddon.healthAvailable,
                  store.pocketKernelAddon.providerAvailable else {
                chat.errorMessage = store.pocketKernelAddon.status.title
                return
            }
            normalizeKernelBaseURLPreference()
            chat.sendViaPocketKernel(
                baseURL: effectiveKernelBaseURL,
                userID: middlewareAuthProfileID,
                index: store.index,
                selectedPageID: store.selectedPageID
            )
        }
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
        if lmStudioModelID.pocketTrimmed.isEmpty,
           providerMethod == .lmStudio,
           let legacyModel = UserDefaults.standard.string(forKey: "PocketWikiMac.localAI.modelID")?.pocketTrimmed,
           !legacyModel.isEmpty {
            lmStudioModelID = legacyModel
        }
        store.localAIConfiguredModelID = runtime.modelID
        store.localAIRuntimeAPIKey = runtime.apiKey
        store.localAIRuntimeTokenLoaded = runtime.hasToken
        store.middlewareAuthClientToken = store.serverConfiguration.middlewareAuthClientToken
        store.middlewareAuthRuntimeTokenLoaded = !store.serverConfiguration.middlewareAuthClientToken.pocketTrimmed.isEmpty
        if kernelBaseURL.pocketTrimmed.isEmpty || kernelBaseURL == PocketKernelEndpointPolicy.defaultBaseURL {
            kernelBaseURL = store.serverConfiguration.pocketKernelBaseURL
        }
        if middlewareAuthBaseURL.pocketTrimmed.isEmpty || middlewareAuthBaseURL == MiddlewareAuthEndpointPolicy.defaultBaseURL {
            middlewareAuthBaseURL = store.serverConfiguration.middlewareAuthBaseURL
        }
        if middlewareAuthProjectID.pocketTrimmed.isEmpty || middlewareAuthProjectID == "acme" {
            middlewareAuthProjectID = store.serverConfiguration.middlewareAuthProjectID
        }
        if middlewareAuthProfileID.pocketTrimmed.isEmpty || middlewareAuthProfileID == "default" {
            middlewareAuthProfileID = store.serverConfiguration.middlewareAuthProfileID
        }
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)

        let runtimeBaseURL = runtime.baseURL.pocketTrimmed
        if !runtimeBaseURL.isEmpty, baseURL.pocketTrimmed.isEmpty || baseURL == LocalAIEndpointPolicy.defaultBaseURL {
            baseURL = runtimeBaseURL
        }
        if lmStudioModelID.pocketTrimmed.isEmpty, !runtime.modelID.pocketTrimmed.isEmpty {
            lmStudioModelID = runtime.modelID
        }
        if openAIModelID.pocketTrimmed.isEmpty {
            openAIModelID = "gpt-5.5"
        }
        normalizeBaseURLPreference()
        await syncPocketKernelProvider()
    }

    @MainActor
    private func runPrimaryProviderAction() async {
        switch providerMethod {
        case .openAI:
            await startOpenAILogin()
        case .lmStudio:
            if pendingLMStudioAPIKey.isEmpty {
                await refreshProviderStatus()
            } else {
                await configureProvider()
            }
        }
    }

    @MainActor
    private func refreshProviderStatus() async {
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        await chat.refreshProviderStatus(
            method: providerMethod,
            middlewareBaseURL: middlewareAuthBaseURL,
            clientToken: store.middlewareAuthClientToken,
            projectID: middlewareAuthProjectID,
            profileID: middlewareAuthProfileID
        )
    }

    @MainActor
    private func startOpenAILogin() async {
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        guard let login = await chat.startOpenAILogin(
            middlewareBaseURL: middlewareAuthBaseURL,
            clientToken: store.middlewareAuthClientToken,
            projectID: middlewareAuthProjectID,
            profileID: middlewareAuthProfileID
        ) else {
            return
        }
        let urlText = login.authUrl?.pocketTrimmed.pocketIfEmpty(login.verificationUrl?.pocketTrimmed ?? "") ?? login.verificationUrl?.pocketTrimmed ?? ""
        if let url = URL(string: urlText), !urlText.isEmpty {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    private func configureProvider(silent: Bool = false) async {
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        normalizeBaseURLPreference()
        if silent {
            chat.errorMessage = nil
        }
        let selected = await chat.configureLMStudioProvider(
            middlewareBaseURL: middlewareAuthBaseURL,
            clientToken: store.middlewareAuthClientToken,
            projectID: middlewareAuthProjectID,
            profileID: middlewareAuthProfileID,
            lmStudioBaseURL: baseURL,
            apiKey: pendingLMStudioAPIKey,
            preferredModelID: selectedModelID,
            configuredModelID: store.localAIConfiguredModelID
        )
        if let selected {
            lmStudioModelID = selected
        } else if lmStudioModelID.pocketTrimmed.isEmpty, !store.localAIConfiguredModelID.pocketTrimmed.isEmpty {
            lmStudioModelID = store.localAIConfiguredModelID
        }
        if chat.errorMessage == nil {
            // MiddlewareAuth passa a ser o único dono persistente do secret.
            store.localAIAPIKey = ""
            await syncPocketKernelProvider()
        }
    }

    @MainActor
    private func syncPocketKernelProvider() async {
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        await store.configurePocketKernelProvider(
            baseURL: kernelBaseURL,
            providerID: providerMethod.rawValue,
            modelID: selectedModelID,
            reasoningEffort: reasoningEffortRaw,
            middlewareBaseURL: middlewareAuthBaseURL,
            projectID: middlewareAuthProjectID,
            profileID: middlewareAuthProfileID
        )
    }

    private func normalizeBaseURLPreference() {
        guard let url = URL(string: baseURL.pocketTrimmed),
              LocalAIEndpointPolicy.isAllowedLocalBaseURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let cleanPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleanPath.isEmpty || cleanPath == "v1" {
            components.path = ""
        } else {
            components.path = "/" + cleanPath
        }
        guard let value = components.url?.absoluteString.pocketTrimmedSlash else { return }
        if baseURL != value {
            baseURL = value
        }
    }

    private func normalizeKernelBaseURLPreference() {
        guard store.remoteKernelQueryURL == nil else { return }
        guard let url = try? PocketKernelEndpointPolicy.kernelURL(kernelBaseURL) else { return }
        let text = url.absoluteString
        if kernelBaseURL != text {
            kernelBaseURL = text
        }
    }
}
