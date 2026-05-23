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
    let contextSummary: String
    let contextSourceCount: Int
    let onRefreshModels: () async -> Void
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
            ScrollView {
                Text(contextSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 190)
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
