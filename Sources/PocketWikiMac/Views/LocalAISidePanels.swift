import SwiftUI

enum LocalAISideRailOrientation {
    case vertical
    case horizontal
}

struct LocalAISideRail: View {
    @Binding var selection: LocalAISidePanel?
    let orientation: LocalAISideRailOrientation

    var body: some View {
        Group {
            switch orientation {
            case .vertical:
                VStack(spacing: 8) {
                    buttons
                }
            case .horizontal:
                HStack(spacing: 6) {
                    buttons
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        sideButton(.llm)
        sideButton(.context)
    }

    private func sideButton(_ panel: LocalAISidePanel) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                selection = selection == panel ? nil : panel
            }
        } label: {
            Image(systemName: panel.systemImage)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == panel ? PocketWikiTheme.accent : PocketWikiTheme.dim)
        .background(
            selection == panel ? PocketWikiTheme.accent.opacity(0.11) : PocketWikiTheme.bg3.opacity(0.75),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selection == panel ? PocketWikiTheme.accent.opacity(0.55) : PocketWikiTheme.border, lineWidth: 1)
        }
        .help(panel.title)
    }
}

struct LocalAISidePanelContent: View {
    let panel: LocalAISidePanel
    @Binding var providerMethodRaw: String
    @Binding var reasoningEffortRaw: String
    @Binding var kernelBaseURL: String
    @Binding var middlewareAuthBaseURL: String
    @Binding var middlewareAuthProjectID: String
    @Binding var middlewareAuthProfileID: String
    @Binding var baseURL: String
    @Binding var modelID: String
    @Binding var middlewareAuthToken: String
    @Binding var apiKey: String
    let availableModels: [LocalAIModel]
    let middlewareRuntimeTokenLoaded: Bool
    let runtimeTokenLoaded: Bool
    let isStreaming: Bool
    let providerStatusText: String
    let contextNotice: String?
    let autoContextPaths: [String]
    let manualSources: [LocalAIManualContextSource]
    let excludedContextPaths: Set<String>
    let contextSourceCount: Int
    let onPrimaryProviderAction: () async -> Void
    let onRefreshModels: () async -> Void
    let onOpenAdvancedSettings: () -> Void
    let onAddContextFiles: () -> Void
    let onRemoveManualSource: (UUID) -> Void
    let onExcludeContextPath: (String) -> Void
    let onRestoreContextPath: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        switch panel {
        case .llm:
            llmPanel
        case .context:
            contextPanel
        }
    }

    private var llmPanel: some View {
        let method = LocalAIProviderMethod.value(for: providerMethodRaw)
        return LocalAISideCard(
            title: "IA",
            subtitle: method.title,
            systemImage: method.systemImage,
            close: onClose
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    LocalAIFieldLabel("Método")
                    Picker("", selection: $providerMethodRaw) {
                        ForEach(LocalAIProviderMethod.allCases) { provider in
                            Label(provider.title, systemImage: provider.systemImage)
                                .tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .localAIInputChrome()
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        LocalAIFieldLabel("Modelo")
                        Picker("", selection: $modelID) {
                            ForEach(modelOptions(for: method), id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .localAIInputChrome()
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 5) {
                        LocalAIFieldLabel("Raciocínio")
                        Picker("", selection: $reasoningEffortRaw) {
                            ForEach(LocalAIReasoningEffort.allCases) { effort in
                                Text(effort.title).tag(effort.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .localAIInputChrome()
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await onPrimaryProviderAction() }
                    } label: {
                        Label(method.primaryActionTitle, systemImage: method == .openAI ? "person.crop.circle.badge.checkmark" : "wrench.and.screwdriver")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketWikiTheme.text)
                    .pocketWikiSurface(cornerRadius: 13, tint: PocketWikiTheme.accent)
                    .disabled(isStreaming)
                    .frame(minWidth: 0, maxWidth: .infinity)

                    Button {
                        Task { await onRefreshModels() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketWikiTheme.accent)
                    .pocketWikiSurface(cornerRadius: 13)
                    .disabled(isStreaming)
                    .help("Atualizar status")

                    Button(action: onOpenAdvancedSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketWikiTheme.dim)
                    .pocketWikiSurface(cornerRadius: 13)
                    .help("Configurações avançadas")
                }

                Text(providerStatusText.pocketTrimmed.pocketIfEmpty(method.statusFallback))
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
                    .padding(.top, 1)
                    .lineLimit(2)
            }
        }
    }

    private func modelOptions(for method: LocalAIProviderMethod) -> [String] {
        let current = modelID.pocketTrimmed
        let defaults: [String]
        switch method {
        case .openAI:
            defaults = ["gpt-5.5"]
        case .lmStudio:
            defaults = availableModels.map(\.id)
        }
        var values: [String] = []
        for value in ([current] + defaults).map(\.pocketTrimmed).filter({ !$0.isEmpty }) {
            if !values.contains(value) {
                values.append(value)
            }
        }
        if !values.isEmpty {
            return values
        }
        return method == .openAI ? ["gpt-5.5"] : ["modelo local"]
    }

    private var contextPanel: some View {
        LocalAISideCard(
            title: "Contexto",
            subtitle: "\(contextSourceCount) fonte(s)",
            systemImage: "doc.text",
            close: onClose
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button(action: onAddContextFiles) {
                        Label("Adicionar", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .controlSize(.small)
                    .disabled(isStreaming)

                    if !excludedContextPaths.isEmpty {
                        Text("\(excludedContextPaths.count) removida(s)")
                            .font(.caption.monospaced())
                            .foregroundStyle(PocketWikiTheme.warn)
                    }
                }

                if let contextNotice, !contextNotice.isEmpty {
                    Text(contextNotice)
                        .font(.caption.monospaced())
                        .foregroundStyle(PocketWikiTheme.warn)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if autoContextPaths.isEmpty, manualSources.isEmpty, excludedContextPaths.isEmpty {
                            Text("sem contexto carregado")
                                .font(.caption.monospaced())
                                .foregroundStyle(PocketWikiTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(autoContextPaths, id: \.self) { path in
                            LocalAIContextSourceRow(
                                title: path,
                                subtitle: excludedContextPaths.contains(path) ? "removida do proximo envio" : "fonte selecionada pela busca",
                                systemImage: "doc.text",
                                isRemoved: excludedContextPaths.contains(path),
                                actionTitle: excludedContextPaths.contains(path) ? "Restaurar" : "Remover",
                                actionSystemImage: excludedContextPaths.contains(path) ? "arrow.uturn.backward" : "minus.circle",
                                action: {
                                    if excludedContextPaths.contains(path) {
                                        onRestoreContextPath(path)
                                    } else {
                                        onExcludeContextPath(path)
                                    }
                                }
                            )
                        }

                        ForEach(manualSources) { source in
                            LocalAIContextSourceRow(
                                title: source.title,
                                subtitle: "\(source.path) · \(source.characters) chars",
                                systemImage: "paperclip",
                                isRemoved: false,
                                actionTitle: "Remover",
                                actionSystemImage: "minus.circle",
                                action: { onRemoveManualSource(source.id) }
                            )
                        }
                    }
                    .animation(.snappy(duration: 0.18), value: autoContextPaths)
                    .animation(.snappy(duration: 0.18), value: manualSources)
                    .animation(.snappy(duration: 0.18), value: excludedContextPaths)
                }
                .frame(maxHeight: 230)
            }
        }
    }
}

struct LocalAIAdvancedSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var providerMethodRaw: String
    @Binding var reasoningEffortRaw: String
    @Binding var kernelBaseURL: String
    @Binding var middlewareAuthBaseURL: String
    @Binding var middlewareAuthProjectID: String
    @Binding var middlewareAuthProfileID: String
    @Binding var baseURL: String
    @Binding var modelID: String
    @Binding var middlewareAuthToken: String
    @Binding var apiKey: String
    let middlewareRuntimeTokenLoaded: Bool
    let runtimeTokenLoaded: Bool
    let middlewareAddonStatus: MiddlewareAuthAddonStatus
    let middlewareAddonAccessVerified: Bool
    let pocketKernelAddonStatus: PocketKernelAddonStatus
    let pocketKernelAddonReady: Bool
    let onRestartMiddlewareAddon: () async -> Void
    let onRestartPocketKernelAddon: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Configurações da IA", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(PocketWikiTheme.text)

                Spacer()

                Button("Fechar") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    providerSection
                    infraSection
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .frame(width: 540, height: 560)
        .background(PocketWikiTheme.bg)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Provider", systemImage: LocalAIProviderMethod.value(for: providerMethodRaw).systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PocketWikiTheme.text)

            LocalAIFieldLabel("Método")
            Picker("", selection: $providerMethodRaw) {
                ForEach(LocalAIProviderMethod.allCases) { provider in
                    Text(provider.title).tag(provider.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    LocalAIFieldLabel("Modelo")
                    TextField("", text: $modelID, prompt: Text("gpt-5.5 ou modelo local"))
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .localAIInputChrome()
                }

                VStack(alignment: .leading, spacing: 5) {
                    LocalAIFieldLabel("Raciocínio")
                    Picker("", selection: $reasoningEffortRaw) {
                        ForEach(LocalAIReasoningEffort.allCases) { effort in
                            Text(effort.title).tag(effort.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .localAIInputChrome()
                }
            }

            LocalAIFieldLabel("LM Studio base URL")
            TextField("", text: $baseURL, prompt: Text("http://127.0.0.1:1234"))
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .localAIInputChrome()

            LocalAIFieldLabel("LM Studio API key")
            SecureField("", text: $apiKey, prompt: Text("nova chave, somente para configurar"))
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .localAIInputChrome()

            Text("OpenAI usa login/status pelo MiddlewareAuth. LM Studio só substitui a credencial quando uma nova chave é informada; em branco, mantém a já armazenada.")
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.muted)
        }
        .padding(14)
        .pocketWikiCard()
    }

    private var infraSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Infra", systemImage: "network")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PocketWikiTheme.text)

            LocalAIFieldLabel("PocketKernel")
            TextField("", text: $kernelBaseURL, prompt: Text(PocketKernelEndpointPolicy.defaultBaseURL))
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .localAIInputChrome()

            LocalAIFieldLabel("MiddlewareAuth")
            TextField("", text: $middlewareAuthBaseURL, prompt: Text(MiddlewareAuthEndpointPolicy.defaultBaseURL))
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .localAIInputChrome()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    LocalAIFieldLabel("Project ID")
                    TextField("", text: $middlewareAuthProjectID, prompt: Text("acme"))
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .localAIInputChrome()
                }

                VStack(alignment: .leading, spacing: 5) {
                    LocalAIFieldLabel("Profile/User ID")
                    TextField("", text: $middlewareAuthProfileID, prompt: Text("default"))
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .localAIInputChrome()
                }
            }

            if middlewareRuntimeTokenLoaded {
                Text("MIDDLEWARE_CLIENT_TOKEN carregado do runtime do servidor.")
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
            } else {
                LocalAIFieldLabel("Middleware token")
                SecureField("", text: $middlewareAuthToken, prompt: Text("MIDDLEWARE_CLIENT_TOKEN"))
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .localAIInputChrome()
            }

            Text("Perguntas continuam saindo pelo PocketKernel Harness; estes campos só configuram auth/provider.")
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.muted)

            addonStatusRow(
                ready: pocketKernelAddonReady,
                title: pocketKernelAddonStatus.title,
                action: onRestartPocketKernelAddon
            )

            addonStatusRow(
                ready: middlewareAddonAccessVerified,
                title: middlewareAddonStatus.title,
                action: onRestartMiddlewareAddon
            )
        }
        .padding(14)
        .pocketWikiCard()
    }

    private func addonStatusRow(
        ready: Bool,
        title: String,
        action: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: 8) {
                Circle()
                    .fill(ready ? PocketWikiTheme.good : PocketWikiTheme.warn)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
                    .lineLimit(2)
                Spacer()
                Button("Reiniciar") {
                    Task { await action() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
    }
}

private struct LocalAIContextSourceRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isRemoved: Bool
    let actionTitle: String
    let actionSystemImage: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(isRemoved ? PocketWikiTheme.warn : PocketWikiTheme.accent2)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.monospaced())
                    .foregroundStyle(isRemoved ? PocketWikiTheme.muted : PocketWikiTheme.text)
                    .strikethrough(isRemoved, color: PocketWikiTheme.warn)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(isRemoved ? PocketWikiTheme.warn : PocketWikiTheme.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 4)

            Button(action: action) {
                Image(systemName: actionSystemImage)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isRemoved ? PocketWikiTheme.good : PocketWikiTheme.bad)
            .help(actionTitle)
        }
        .padding(8)
        .background(isRemoved ? PocketWikiTheme.warn.opacity(0.08) : PocketWikiTheme.bg.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isRemoved ? PocketWikiTheme.warn.opacity(0.38) : PocketWikiTheme.border, lineWidth: 1)
        }
    }
}

private struct LocalAISideCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(PocketWikiTheme.text)

                Spacer(minLength: 8)

                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
                    .lineLimit(1)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketWikiTheme.dim)
                .pocketWikiSurface(cornerRadius: 12)
                .help("Recolher")
            }

            content
        }
        .padding(16)
        .pocketWikiCard()
    }
}

private struct LocalAIFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.monospaced())
            .foregroundStyle(PocketWikiTheme.muted)
            .tracking(1.1)
    }
}

private struct LocalAIInputChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(PocketWikiTheme.text)
            .background(PocketWikiTheme.bg.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(PocketWikiTheme.border, lineWidth: 1)
            }
    }
}

private extension View {
    func localAIInputChrome() -> some View {
        modifier(LocalAIInputChrome())
    }
}
