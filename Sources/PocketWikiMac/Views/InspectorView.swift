import SwiftUI

struct InspectorView: View {
    @Bindable var store: WikiAppStore
    let page: WikiPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inspector")
                        .font(.headline)
                        .foregroundStyle(PocketWikiTheme.text)
                    Text(page.path)
                        .font(.caption)
                        .foregroundStyle(PocketWikiTheme.muted)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                SectionCard("Metricas", systemImage: "chart.bar") {
                    metric("Palavras", "\(page.wordCount)")
                    metric("Leitura", "\(page.readingMinutes) min")
                    metric("Backlinks", "\(page.backlinks.count)")
                    metric("Outlinks", "\(page.outlinks.count)")
                    metric("Ausentes", "\(page.missingLinks.count)")
                    metric("Atualizado", PocketFormatters.date(page.updatedAt))
                }

                SectionCard("Tags", systemImage: "tag") {
                    if page.tags.isEmpty {
                        Text("sem tags")
                            .foregroundStyle(PocketWikiTheme.muted)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(page.tags, id: \.self) { tag in
                                Button("#\(tag)") { store.selectTag(tag) }
                                    .tint(PocketWikiTheme.accent2)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                linkCard(title: "Backlinks", ids: page.backlinks, image: "arrowshape.turn.up.left")
                linkCard(title: "Outlinks", ids: page.outlinks.map(\.resolvedPageID), image: "link")

                SectionCard("Ausentes", systemImage: "exclamationmark.triangle") {
                    if page.missingLinks.isEmpty {
                        Label("nenhum link quebrado", systemImage: "checkmark.circle")
                            .foregroundStyle(PocketWikiTheme.good)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(page.missingLinks) { link in
                                Text(link.label)
                                    .foregroundStyle(PocketWikiTheme.bad)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(PocketWikiTheme.bg2.opacity(0.96))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(PocketWikiTheme.muted)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(PocketWikiTheme.text)
                .lineLimit(1)
        }
        .font(.caption)
    }

    private func linkCard(title: String, ids: [String], image: String) -> some View {
        SectionCard(title, subtitle: "\(ids.count)", systemImage: image) {
            if ids.isEmpty {
                Text("nada encontrado")
                    .foregroundStyle(PocketWikiTheme.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ids.prefix(12), id: \.self) { id in
                        if let linked = store.index.page(id: id) {
                            PageListButton(page: linked, meta: linked.path) {
                                store.selectPage(linked.id)
                            }
                        }
                    }
                }
            }
        }
    }
}
