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
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selection == panel ? PocketWikiTheme.accent.opacity(0.55) : PocketWikiTheme.border, lineWidth: 1)
        }
        .help(panel.title)
    }
}

struct LocalAISidePanelContent: View {
    let panel: LocalAISidePanel
    @Binding var baseURL: String
    @Binding var modelID: String
    @Binding var apiKey: String
    let availableModels: [LocalAIModel]
    let runtimeTokenLoaded: Bool
    let isStreaming: Bool
    let contextNotice: String?
    let autoContextPaths: [String]
    let manualSources: [LocalAIManualContextSource]
    let excludedContextPaths: Set<String>
    let contextSourceCount: Int
    let onRefreshModels: () async -> Void
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
        LocalAISideCard(
            title: "LM Studio",
            subtitle: availableModels.isEmpty ? "offline" : "ok",
            systemImage: "server.rack",
            close: onClose
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LocalAIFieldLabel("Base URL")
                TextField("", text: $baseURL)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .localAIInputChrome()

                LocalAIFieldLabel("Modelo")
                if availableModels.isEmpty {
                    TextField("", text: $modelID)
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .localAIInputChrome()
                } else {
                    Picker("Modelo", selection: $modelID) {
                        ForEach(availableModels) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }

                if !runtimeTokenLoaded {
                    LocalAIFieldLabel("Token")
                    SecureField("", text: $apiKey, prompt: Text("LM_STUDIO_API_KEY"))
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .localAIInputChrome()
                }

                Button {
                    Task {
                        await onRefreshModels()
                    }
                } label: {
                    Label("Atualizar modelos", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .tint(PocketWikiTheme.accent)
                .disabled(isStreaming)

                Text(runtimeTokenLoaded ? "usando configuracao local do PocketWiki" : "chamada direta ao LM Studio")
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
            }
        }
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
        VStack(alignment: .leading, spacing: 12) {
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
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketWikiTheme.dim)
                .background(PocketWikiTheme.bg3.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PocketWikiTheme.border, lineWidth: 1)
                }
                .help("Recolher")
            }

            content
        }
        .padding(14)
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
            .padding(.vertical, 9)
            .foregroundStyle(PocketWikiTheme.text)
            .background(PocketWikiTheme.bg.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(PocketWikiTheme.border, lineWidth: 1)
            }
    }
}

private extension View {
    func localAIInputChrome() -> some View {
        modifier(LocalAIInputChrome())
    }
}
