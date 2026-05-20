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
                                .lineLimit(1)
                            Text(page.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(page.id as String?)
                    }
                }
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)

                Divider()

                detail(page: selectedPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                selectedID = selectedID ?? store.selectedPageID ?? drawings.first?.id
            }
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
                        .foregroundStyle(.secondary)
                    Text(page.title)
                        .font(.largeTitle.bold())

                    if let summary = page.excalidraw {
                        FlowLayout(spacing: 8) {
                            Label("\(summary.stats.elements) elementos", systemImage: "square.stack.3d.up")
                            Label("\(summary.stats.textElements) textos", systemImage: "text.quote")
                            Label("\(summary.stats.links) links", systemImage: "link")
                            if let reason = summary.fallbackReason {
                                Label(reason, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            } else {
                                Label("cena JSON textual", systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        store.selectPage(page.id, tab: .reader)
                    } label: {
                        Label("Abrir indice no leitor", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let summary = page.excalidraw {
                    SectionCard("Preview textual", subtitle: "\(summary.texts.count) textos", systemImage: "text.alignleft") {
                        if summary.texts.isEmpty {
                            Text("sem texto extraido")
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                                ForEach(Array(summary.texts.prefix(80).enumerated()), id: \.offset) { _, text in
                                    Text(text)
                                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                                        .multilineTextAlignment(.center)
                                        .padding(10)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }

                    SectionCard("Relacoes textuais", subtitle: "\(summary.relationHints.count)", systemImage: "arrow.right") {
                        if summary.relationHints.isEmpty {
                            Text("sem relacoes inferidas")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(summary.relationHints.prefix(12), id: \.self) { relation in
                                    Text(relation)
                                        .font(.callout)
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
