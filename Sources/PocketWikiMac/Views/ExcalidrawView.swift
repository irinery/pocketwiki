import SwiftUI

struct ExcalidrawView: View {
    @Bindable var store: WikiAppStore
    @State private var selectedID: String?

    private var drawings: [WikiPage] {
        store.index.pages.filter { $0.kind == .excalidraw }
    }

    private var selectedPage: WikiPage? {
        if let selectedID, let page = store.index.page(id: selectedID), page.kind == .excalidraw {
            return page
        }
        return drawings.first
    }

    var body: some View {
        if drawings.isEmpty {
            EmptyStateView(
                title: "Nenhum Excalidraw encontrado",
                message: "A aba mostra arquivos `.excalidraw` e `.excalidraw.md` reconhecidos pelo parser textual.",
                systemImage: "scribble.variable"
            )
        } else if let page = selectedPage {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(page)

                    if let summary = page.excalidraw {
                        preview(summary)
                        relations(summary)
                    }
                }
                .padding(22)
                .frame(maxWidth: 1120, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(PocketWikiTheme.appBackground)
            .onAppear {
                selectedID = selectedID ?? store.selectedPageID ?? drawings.first?.id
            }
        }
    }

    private func header(_ page: WikiPage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 34))
                    .foregroundStyle(PocketWikiTheme.purple)
                    .frame(width: 56, height: 56)
                    .background(PocketWikiTheme.bg3, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(PocketWikiTheme.border, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 7) {
                    Text(page.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(PocketWikiTheme.muted)
                        .textSelection(.enabled)
                    Text(page.title)
                        .font(.system(size: 34, weight: .heavy, design: .serif))
                        .foregroundStyle(PocketWikiTheme.text)
                        .lineLimit(2)

                    if let summary = page.excalidraw {
                        FlowLayout(spacing: 8) {
                            Label("\(summary.stats.elements) elementos", systemImage: "square.stack.3d.up")
                            Label("\(summary.stats.textElements) textos", systemImage: "text.quote")
                            Label("\(summary.stats.links) links", systemImage: "link")
                            if let reason = summary.fallbackReason {
                                Label(reason, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(PocketWikiTheme.warn)
                            } else {
                                Label("cena JSON textual", systemImage: "checkmark.circle")
                                    .foregroundStyle(PocketWikiTheme.good)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(PocketWikiTheme.dim)
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 10) {
                    Picker("", selection: bindingSelectedID) {
                        ForEach(drawings) { drawing in
                            Text(drawing.title).tag(drawing.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)

                    Button {
                        store.selectPage(page.id, tab: .reader)
                    } label: {
                        Label("Abrir indice", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .tint(PocketWikiTheme.accent)
                }
            }
        }
        .padding(18)
        .pocketWikiCard(hero: true)
    }

    private var bindingSelectedID: Binding<String> {
        Binding(
            get: { selectedID ?? drawings.first?.id ?? "" },
            set: { selectedID = $0 }
        )
    }

    private func preview(_ summary: ExcalidrawSummary) -> some View {
        SectionCard("Preview textual", subtitle: "\(summary.texts.count) textos extraidos", systemImage: "text.alignleft") {
            if summary.texts.isEmpty {
                Text("sem texto extraido")
                    .foregroundStyle(PocketWikiTheme.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(summary.texts.prefix(32).enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "text.quote")
                                .foregroundStyle(PocketWikiTheme.accent)
                                .frame(width: 18)
                            Text(text)
                                .foregroundStyle(PocketWikiTheme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(PocketWikiTheme.bg2.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(PocketWikiTheme.border, lineWidth: 1)
                        }
                    }

                    if summary.texts.count > 32 {
                        Text("+ \(summary.texts.count - 32) textos ocultos no preview")
                            .font(.caption)
                            .foregroundStyle(PocketWikiTheme.muted)
                    }
                }
            }
        }
    }

    private func relations(_ summary: ExcalidrawSummary) -> some View {
        SectionCard("Relacoes textuais", subtitle: "\(summary.relationHints.count)", systemImage: "arrow.right") {
            if summary.relationHints.isEmpty {
                Text("sem relacoes inferidas")
                    .foregroundStyle(PocketWikiTheme.muted)
            } else {
                DisclosureGroup("Ver relacoes") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.relationHints.prefix(24), id: \.self) { relation in
                            Text(relation)
                                .foregroundStyle(PocketWikiTheme.text)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 8)
                }
                .tint(PocketWikiTheme.accent)
            }
        }
    }
}
