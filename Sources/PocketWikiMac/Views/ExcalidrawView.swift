import SwiftUI

struct ExcalidrawView: View {
    @Bindable var store: WikiAppStore
    @State private var selectedID: String?

    private var drawings: [WikiPage] {
        store.index.pages.filter { $0.kind == .excalidraw }
    }

    var body: some View {
        if drawings.isEmpty {
            EmptyStateView(
                title: "Nenhum Excalidraw encontrado",
                message: "A aba mostra arquivos `.excalidraw` e `.excalidraw.md` reconhecidos pelo parser textual.",
                systemImage: "scribble.variable"
            )
        } else {
            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(drawings) { page in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title)
                                .foregroundStyle(PocketWikiTheme.text)
                                .lineLimit(1)
                            Text(page.path)
                                .font(.caption)
                                .foregroundStyle(PocketWikiTheme.muted)
                                .lineLimit(1)
                        }
                        .tag(page.id as String?)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(PocketWikiTheme.bg2)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)

                Rectangle()
                    .fill(PocketWikiTheme.border)
                    .frame(width: 1)

                detail(page: selectedPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                selectedID = selectedID ?? store.selectedPageID ?? drawings.first?.id
            }
            .background(PocketWikiTheme.appBackground)
        }
    }

    private var selectedPage: WikiPage {
        if let selectedID, let page = store.index.page(id: selectedID), page.kind == .excalidraw {
            return page
        }
        return drawings[0]
    }

    private func detail(page: WikiPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(page.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(PocketWikiTheme.muted)
                    Text(page.title)
                        .font(.system(size: 34, weight: .heavy, design: .serif))
                        .foregroundStyle(PocketWikiTheme.text)

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

                    Button {
                        store.selectPage(page.id, tab: .reader)
                    } label: {
                        Label("Abrir indice no leitor", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PocketWikiTheme.accent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                }

                if let summary = page.excalidraw {
                    SectionCard("Preview textual", subtitle: "\(summary.texts.count) textos", systemImage: "text.alignleft") {
                        if summary.texts.isEmpty {
                            Text("sem texto extraido")
                                .foregroundStyle(PocketWikiTheme.muted)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                                ForEach(Array(summary.texts.prefix(80).enumerated()), id: \.offset) { _, text in
                                    Text(text)
                                        .foregroundStyle(PocketWikiTheme.text)
                                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                                        .multilineTextAlignment(.center)
                                        .padding(10)
                                        .background(PocketWikiTheme.bg2.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(PocketWikiTheme.border, lineWidth: 1)
                                        }
                                }
                            }
                        }
                    }

                    SectionCard("Relacoes textuais", subtitle: "\(summary.relationHints.count)", systemImage: "arrow.right") {
                        if summary.relationHints.isEmpty {
                            Text("sem relacoes inferidas")
                                .foregroundStyle(PocketWikiTheme.muted)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(summary.relationHints.prefix(12), id: \.self) { relation in
                                    Text(relation)
                                        .font(.callout)
                                        .foregroundStyle(PocketWikiTheme.text)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}
