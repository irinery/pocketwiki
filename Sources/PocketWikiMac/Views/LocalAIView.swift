import AppKit
import SwiftUI

struct LocalAIView: View {
    @Bindable var store: WikiAppStore

    @AppStorage("PocketWikiMac.localAI.providerMethod") private var providerMethodRaw = "openai"
    @AppStorage("PocketWikiMac.localAI.reasoningEffort") private var reasoningEffortRaw = LocalAIReasoningEffort.medium.rawValue
    @AppStorage("PocketWikiMac.localAI.baseURL") private var baseURL = "http://127.0.0.1:1234"
    @AppStorage("PocketWikiMac.localAI.kernelBaseURL") private var kernelBaseURL = PocketKernelEndpointPolicy.defaultBaseURL
    @AppStorage("PocketWikiMac.localAI.middlewareBaseURL") private var middlewareAuthBaseURL = MiddlewareAuthEndpointPolicy.defaultBaseURL
    @AppStorage("PocketWikiMac.localAI.middlewareProjectID") private var middlewareAuthProjectID = "acme"
    @AppStorage("PocketWikiMac.localAI.middlewareProfileID") private var middlewareAuthProfileID = "default"
    @AppStorage("PocketWikiMac.localAI.openAIModelID") private var openAIModelID = "gpt-5.5"
    @AppStorage("PocketWikiMac.localAI.lmStudioModelID") private var lmStudioModelID = ""
    @State private var providerModelIDs: [String: String] = [:]
    @State private var providerCredentialFields: [String: [String: String]] = [:]
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

    private var providerMethod: MiddlewareAuthLLMProvider? {
        chat.availableProviders.first { $0.normalizedID == providerMethodRaw.pocketTrimmed.lowercased() }
    }

    private var selectedModelID: String {
        switch providerMethodRaw.pocketTrimmed.lowercased() {
        case "openai": openAIModelID
        case "lmstudio": lmStudioModelID
        default:
            providerModelIDs[providerMethodRaw]
                ?? UserDefaults.standard.string(forKey: modelPreferenceKey(for: providerMethodRaw))
                ?? providerMethod?.defaultModelID
                ?? ""
        }
    }

    private var selectedModelIDBinding: Binding<String> {
        Binding(
            get: { selectedModelID },
            set: { value in
                switch providerMethodRaw.pocketTrimmed.lowercased() {
                case "openai":
                    openAIModelID = value
                case "lmstudio":
                    lmStudioModelID = value
                default:
                    providerModelIDs[providerMethodRaw] = value
                    UserDefaults.standard.set(value, forKey: modelPreferenceKey(for: providerMethodRaw))
                }
            }
        )
    }

    private var selectedProviderAuthFields: Binding<[String: String]> {
        Binding(
            get: {
                var values = providerCredentialFields[providerMethodRaw] ?? [:]
                if providerMethodRaw == "lmstudio" {
                    values["baseUrl"] = baseURL
                    values["apiKey"] = store.localAIAPIKey
                }
                return values
            },
            set: { values in
                providerCredentialFields[providerMethodRaw] = values
                if providerMethodRaw == "lmstudio" {
                    baseURL = values["baseUrl"] ?? baseURL
                    store.localAIAPIKey = values["apiKey"] ?? ""
                }
            }
        )
    }

    private func modelPreferenceKey(for providerID: String) -> String {
        "PocketWikiMac.localAI.providerModel.\(providerID.pocketTrimmed.lowercased())"
    }

    private func reconcileReasoningEffort() {
        guard let model = providerMethod?.models.first(where: { $0.id == selectedModelID }),
              let options = model.reasoningEfforts,
              !options.isEmpty,
              !options.contains(where: { $0.id == reasoningEffortRaw }) else { return }
        reasoningEffortRaw = model.defaultReasoningEffort ?? options.first?.id ?? "medium"
    }

    private var providerStatusText: String {
        if let error = chat.errorMessage, !error.pocketTrimmed.isEmpty {
            return error
        }
        let status = chat.statusMessage.pocketTrimmed
        if status.isEmpty || status == "Pronto para conversar com a IA local." {
            return providerMethod?.statusFallback ?? "Carregando provedores do MiddlewareAuth..."
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
                        availableProviders: chat.availableProviders,
                        selectedProvider: providerMethod,
                        reasoningEffortRaw: $reasoningEffortRaw,
                        kernelBaseURL: $kernelBaseURL,
                        middlewareAuthBaseURL: $middlewareAuthBaseURL,
                        middlewareAuthProjectID: $middlewareAuthProjectID,
                        middlewareAuthProfileID: $middlewareAuthProfileID,
                        baseURL: $baseURL,
                        modelID: selectedModelIDBinding,
                        middlewareAuthToken: $store.middlewareAuthClientToken,
                        apiKey: $store.localAIAPIKey,
                        providerAuthFields: selectedProviderAuthFields,
                        availableModels: chat.availableModels,
                        middlewareRuntimeTokenLoaded: store.middlewareAuthRuntimeTokenLoaded,
                        runtimeTokenLoaded: store.localAIRuntimeTokenLoaded,
                        isStreaming: chat.isStreaming,
                        providerStatusText: providerStatusText,
                        providerLoginPrompt: chat.providerLoginPrompt,
                        contextNotice: chat.lastContext?.notice,
                        autoContextPaths: autoContextPaths,
                        manualSources: chat.manualSources,
                        excludedContextPaths: chat.excludedContextPaths,
                        contextSourceCount: activeContextSourceCount,
                        onPrimaryProviderAction: { await runPrimaryProviderAction() },
                        onRefreshModels: { await refreshProviderStatus() },
                        onCopyOpenAICode: copyOpenAICode,
                        onOpenOpenAILogin: openOpenAILogin,
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
                availableProviders: chat.availableProviders,
                selectedProvider: providerMethod,
                providerAuthFields: selectedProviderAuthFields,
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
        .onChange(of: providerMethodRaw) { _, _ in
            guard let providerMethod else { return }
            if selectedModelID.pocketTrimmed.isEmpty ||
                (!providerMethod.models.isEmpty && !providerMethod.models.contains(where: { $0.id == selectedModelID })) {
                selectedModelIDBinding.wrappedValue = providerMethod.models.first(where: { $0.id == providerMethod.defaultModelID })?.id
                    ?? providerMethod.models.first?.id
                    ?? providerMethod.defaultModelID
            }
            reconcileReasoningEffort()
            Task {
                await refreshProviderStatus()
                await syncPocketKernelProvider()
            }
        }
        .onChange(of: selectedModelID) { _, _ in
            reconcileReasoningEffort()
        }
    }

    private var canSendPrompt: Bool {
        guard !chat.prompt.pocketTrimmed.isEmpty else { return false }
        return providerMethod != nil
            && !selectedModelID.pocketTrimmed.isEmpty
            && !effectiveKernelBaseURL.pocketTrimmed.isEmpty
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
            if let providerMethod, providerMethod.needsCredentials,
               providerMethod.auth.fields.contains(where: {
                   $0.required && $0.secret
                       && !(selectedProviderAuthFields.wrappedValue[$0.id] ?? "").pocketTrimmed.isEmpty
               }) {
                await configureProvider(silent: true)
                if chat.errorMessage != nil { return }
            }
            if chat.providerAuthenticated != true {
                await refreshProviderStatus()
            }
            guard chat.providerAuthenticated == true else {
                chat.errorMessage = "Autentique \(providerMethod?.title ?? "um provider") no MiddlewareAuth antes de enviar."
                if providerMethod?.needsCredentials == true {
                    isAdvancedSettingsPresented = true
                }
                return
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
                selectedPageID: store.selectedPageID,
                sourceRootPath: store.pocketMemoryCaptureRootPath,
                providerID: providerMethodRaw,
                modelID: selectedModelID
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
        chat.configurePocketMemory(runtime.pocketMemory, captureRootPath: store.pocketMemoryCaptureRootPath)
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
        await refreshProviderCatalog()

        if providerMethod == nil, let defaultProvider = chat.availableProviders.first(where: { $0.normalizedID == "openai" })
            ?? chat.availableProviders.first {
            providerMethodRaw = defaultProvider.normalizedID
        }
        if let providerMethod,
           selectedModelID.pocketTrimmed.isEmpty ||
            (!providerMethod.models.isEmpty && !providerMethod.models.contains(where: { $0.id == selectedModelID })) {
            selectedModelIDBinding.wrappedValue = providerMethod.models.first(where: { $0.id == providerMethod.defaultModelID })?.id
                ?? providerMethod.models.first?.id
                ?? providerMethod.defaultModelID
        }
        reconcileReasoningEffort()

        let runtimeBaseURL = runtime.baseURL.pocketTrimmed
        if !runtimeBaseURL.isEmpty, baseURL.pocketTrimmed.isEmpty || baseURL == LocalAIEndpointPolicy.defaultBaseURL {
            baseURL = runtimeBaseURL
        }
        if providerMethodRaw == "lmstudio", lmStudioModelID.pocketTrimmed.isEmpty, !runtime.modelID.pocketTrimmed.isEmpty {
            lmStudioModelID = runtime.modelID
        }
        if openAIModelID.pocketTrimmed.isEmpty {
            openAIModelID = "gpt-5.5"
        }
        normalizeBaseURLPreference()
        await refreshProviderStatus()
        await syncPocketKernelProvider()
    }

    @MainActor
    private func runPrimaryProviderAction() async {
        guard let providerMethod else {
            await refreshProviderCatalog()
            return
        }
        if providerMethod.auth.modes.contains("oauth") || providerMethod.auth.modes.contains("device_code") {
            await startProviderLogin()
        } else if providerMethod.needsCredentials {
            let hasRequiredFields = providerMethod.auth.fields
                .filter(\.required)
                .allSatisfy { !(selectedProviderAuthFields.wrappedValue[$0.id] ?? "").pocketTrimmed.isEmpty }
            if hasRequiredFields {
                await configureProvider()
            } else {
                await refreshProviderStatus()
                if chat.providerAuthenticated != true {
                    isAdvancedSettingsPresented = true
                }
            }
        } else {
            await refreshProviderStatus()
        }
    }

    @MainActor
    private func refreshProviderStatus() async {
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        await refreshProviderCatalog()
        guard let providerMethod else { return }
        await chat.refreshProviderStatus(
            providerID: providerMethod.normalizedID,
            providerTitle: providerMethod.title,
            middlewareBaseURL: middlewareAuthBaseURL,
            clientToken: store.middlewareAuthClientToken,
            projectID: middlewareAuthProjectID,
            profileID: middlewareAuthProfileID
        )
    }

    @MainActor
    private func refreshProviderCatalog() async {
        await chat.refreshProviderCatalog(
            middlewareBaseURL: middlewareAuthBaseURL,
            clientToken: store.middlewareAuthClientToken,
            projectID: middlewareAuthProjectID,
            profileID: middlewareAuthProfileID
        )
    }

    @MainActor
    private func startProviderLogin() async {
        guard let providerMethod else { return }
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        guard let login = await chat.startProviderLogin(
            middlewareBaseURL: middlewareAuthBaseURL,
            clientToken: store.middlewareAuthClientToken,
            projectID: middlewareAuthProjectID,
            profileID: middlewareAuthProfileID,
            provider: providerMethod,
            authFields: selectedProviderAuthFields.wrappedValue
        ) else {
            return
        }
        if !login.actionURL.isEmpty {
            openOpenAILogin(login.actionURL)
        }
    }

    @MainActor
    private func copyOpenAICode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    @MainActor
    private func openOpenAILogin(_ urlText: String) {
        guard !urlText.pocketTrimmed.isEmpty,
              let url = URL(string: urlText.pocketTrimmed) else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func configureProvider(silent: Bool = false) async {
        guard let providerMethod else { return }
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        normalizeBaseURLPreference()
        if silent {
            chat.errorMessage = nil
        }
        let selected = await chat.configureProvider(
            middlewareBaseURL: middlewareAuthBaseURL,
            clientToken: store.middlewareAuthClientToken,
            projectID: middlewareAuthProjectID,
            profileID: middlewareAuthProfileID,
            provider: providerMethod,
            authFields: selectedProviderAuthFields.wrappedValue,
            preferredModelID: selectedModelID,
            configuredModelID: store.localAIConfiguredModelID
        )
        if let selected, selectedModelID.pocketTrimmed.isEmpty {
            selectedModelIDBinding.wrappedValue = selected
        }
        if chat.errorMessage == nil {
            var values = selectedProviderAuthFields.wrappedValue
            for field in providerMethod.auth.fields where field.secret {
                values[field.id] = ""
            }
            selectedProviderAuthFields.wrappedValue = values
            await syncPocketKernelProvider()
        }
    }

    @MainActor
    private func syncPocketKernelProvider() async {
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        await store.configurePocketKernelProvider(
            baseURL: kernelBaseURL,
            providerID: providerMethodRaw,
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
