import SwiftUI

struct DashboardView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        let metrics = WikiAnalytics.metrics(for: store.index)
        let hubs = store.index.pages.sorted { $0.connectivityScore > $1.connectivityScore }.filter { $0.connectivityScore >= 4 }
        let orphans = WikiAnalytics.orphanPages(in: store.index)
        let recent = WikiAnalytics.timelinePages(in: store.index).prefix(8)
        let tags = store.index.tagIndex.sorted { $0.value.count > $1.value.count }.prefix(18)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero(metrics)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    SectionCard("Hubs", subtitle: "\(hubs.count)", systemImage: "point.3.connected.trianglepath.dotted") {
                        pageList(Array(hubs.prefix(8)), meta: { "\($0.backlinks.count) back · \($0.outlinks.count) out" })
                    }

                    SectionCard("Links ausentes", subtitle: "\(store.index.missingLinks.count)", systemImage: "exclamationmark.triangle") {
                        if store.index.missingLinks.isEmpty {
                            Text("sem links quebrados")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(store.index.missingLinks.sorted(by: { $0.value.count > $1.value.count }).prefix(8), id: \.key) { item in
                                    HStack {
                                        Text(item.key)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(item.value.count) refs")
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }

                    SectionCard("Tags", subtitle: "\(tags.count)", systemImage: "tag") {
                        FlowLayout(spacing: 8) {
                            ForEach(Array(tags), id: \.key) { tag, pages in
                                Button("#\(tag) · \(pages.count)") {
                                    store.selectTag(tag)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    SectionCard("Orfaos", subtitle: "\(orphans.count)", systemImage: "link.badge.plus") {
                        pageList(Array(orphans.prefix(8)), meta: { $0.folder.isEmpty ? "raiz" : $0.folder })
                    }

                    SectionCard("Recentes", subtitle: "por data", systemImage: "clock") {
                        pageList(Array(recent), meta: { PocketFormatters.date($0.updatedAt) })
                    }

                    SectionCard("Densidade", subtitle: "links por nota", systemImage: "square.grid.3x3") {
                        DensityMiniMap(pages: store.index.pages) { id in
                            store.selectPage(id)
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func hero(_ metrics: WikiDashboardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.index.sourceName)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                    Text("Visao executiva da wiki local: densidade, hubs, buracos de documentacao e paginas recentes.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(metrics.healthScore)/100")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(metrics.healthScore >= 80 ? .green : metrics.healthScore >= 55 ? .orange : .red)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                MetricTile(title: "Paginas", value: "\(metrics.pages)", systemImage: "doc.text")
                MetricTile(title: "Links", value: "\(metrics.links)", systemImage: "link")
                MetricTile(title: "Desenhos", value: "\(metrics.drawings)", systemImage: "scribble.variable")
                MetricTile(title: "Ausentes", value: "\(metrics.missingDestinations)", systemImage: "exclamationmark.triangle")
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func pageList(_ pages: [WikiPage], meta: @escaping (WikiPage) -> String) -> some View {
        Group {
            if pages.isEmpty {
                Text("nada encontrado")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pages) { page in
                        PageListButton(page: page, meta: meta(page)) {
                            store.selectPage(page.id)
                        }
                    }
                }
            }
        }
    }
}

struct DensityMiniMap: View {
    let pages: [WikiPage]
    let open: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 12), spacing: 5)], spacing: 5) {
            ForEach(pages.sorted { density($0) > density($1) }) { page in
                Button {
                    open(page.id)
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(for: page))
                        .frame(height: 12)
                        .help("\(page.title)\n\(page.backlinks.count) back · \(page.outlinks.count) out · \(page.missingLinks.count) ausentes")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 90, alignment: .top)
    }

    private func density(_ page: WikiPage) -> Int {
        page.backlinks.count + page.outlinks.count + page.missingLinks.count
    }

    private func color(for page: WikiPage) -> Color {
        if !page.missingLinks.isEmpty { return .red.opacity(0.75) }
        let value = density(page)
        if value >= 12 { return .orange.opacity(0.8) }
        if value >= 5 { return .blue.opacity(0.7) }
        if value > 0 { return .green.opacity(0.55) }
        return .secondary.opacity(0.25)
    }
}
