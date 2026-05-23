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
            VStack(alignment: .leading, spacing: 18) {
                dashboardHeader(metrics)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        SectionCard("Densidade", subtitle: "links por nota", systemImage: "square.grid.3x3") {
                            DensityMiniMap(pages: store.index.pages) { id in
                                store.selectPage(id)
                            }
                        }
                        .frame(minWidth: 430)

                        SectionCard("Recentes", subtitle: "por data", systemImage: "clock") {
                            pageList(Array(recent), meta: { PocketFormatters.date($0.updatedAt) })
                        }
                        .frame(width: 360)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        SectionCard("Densidade", subtitle: "links por nota", systemImage: "square.grid.3x3") {
                            DensityMiniMap(pages: store.index.pages) { id in
                                store.selectPage(id)
                            }
                        }

                        SectionCard("Recentes", subtitle: "por data", systemImage: "clock") {
                            pageList(Array(recent), meta: { PocketFormatters.date($0.updatedAt) })
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], alignment: .leading, spacing: 16) {
                    SectionCard("Hubs", subtitle: "\(hubs.count)", systemImage: "point.3.connected.trianglepath.dotted") {
                        pageList(Array(hubs.prefix(8)), meta: { "\($0.backlinks.count) back · \($0.outlinks.count) out" })
                    }

                    SectionCard("Links ausentes", subtitle: "\(store.index.missingLinks.count)", systemImage: "exclamationmark.triangle") {
                        missingLinksList()
                    }

                    SectionCard("Tags", subtitle: "\(tags.count)", systemImage: "tag") {
                        tagsList(Array(tags))
                    }

                    SectionCard("Orfaos", subtitle: "\(orphans.count)", systemImage: "link.badge.plus") {
                        pageList(Array(orphans.prefix(8)), meta: { $0.folder.isEmpty ? "raiz" : $0.folder })
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 1360, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(PocketWikiTheme.appBackground)
    }

    private func dashboardHeader(_ metrics: WikiDashboardMetrics) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                hero(metrics)
                    .frame(maxWidth: .infinity)
                quickActions
                    .frame(width: 360)
            }

            VStack(alignment: .leading, spacing: 16) {
                hero(metrics)
                quickActions
            }
        }
    }

    private var quickActions: some View {
        SectionCard("Acoes rapidas", subtitle: "atalhos", systemImage: "bolt") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                DashboardActionTile(icon: "command", title: "Busca", subtitle: "Abrir palette") {
                    store.showSearchPalette = true
                }
                DashboardActionTile(icon: "doc.text", title: "Leitor", subtitle: "Pagina atual") {
                    store.selectedTab = .reader
                }
                DashboardActionTile(icon: "scribble.variable", title: "Desenhos", subtitle: "Excalidraw") {
                    store.selectedTab = .excalidraw
                }
                DashboardActionTile(icon: "waveform.path.ecg", title: "Saude", subtitle: "Fila de acao") {
                    store.selectedTab = .health
                }
                DashboardActionTile(icon: "sparkles", title: "IA", subtitle: "LM Studio") {
                    store.selectedTab = .localAI
                }
            }
        }
    }

    private func missingLinksList() -> some View {
        Group {
            if store.index.missingLinks.isEmpty {
                Text("sem links quebrados")
                    .foregroundStyle(PocketWikiTheme.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.index.missingLinks.sorted(by: { $0.value.count > $1.value.count }).prefix(8), id: \.key) { item in
                        HStack {
                            Text(item.key)
                                .lineLimit(1)
                                .foregroundStyle(PocketWikiTheme.text)
                            Spacer()
                            Text("\(item.value.count) refs")
                                .foregroundStyle(PocketWikiTheme.muted)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func tagsList(_ tags: [(key: String, value: [String])]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.key) { tag, pages in
                Button("#\(tag) · \(pages.count)") {
                    store.selectTag(tag)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .tint(PocketWikiTheme.accent2)
                .controlSize(.small)
            }
        }
    }

    private func hero(_ metrics: WikiDashboardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    BrandLogoView(size: 76)
                    heroText(metrics)
                }

                VStack(alignment: .leading, spacing: 12) {
                    BrandLogoView(size: 76)
                    heroText(metrics)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)], spacing: 10) {
                MetricTile(title: "Paginas", value: "\(metrics.pages)", systemImage: "doc.text")
                MetricTile(title: "Links", value: "\(metrics.links)", systemImage: "link")
                MetricTile(title: "Desenhos", value: "\(metrics.drawings)", systemImage: "scribble.variable")
                MetricTile(title: "Ausentes", value: "\(metrics.missingDestinations)", systemImage: "exclamationmark.triangle")
            }
        }
        .padding(18)
        .pocketWikiCard(hero: true)
    }

    private func heroText(_ metrics: WikiDashboardMetrics) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.index.sourceName)
                    .font(.system(size: 34, weight: .heavy, design: .serif))
                    .foregroundStyle(PocketWikiTheme.text)
                    .lineLimit(2)
                Text("Visao executiva da wiki local: densidade, hubs, buracos de documentacao e paginas recentes.")
                    .foregroundStyle(PocketWikiTheme.dim)
            }
            Spacer()
            Text("\(metrics.healthScore)/100")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(metrics.healthScore >= 80 ? PocketWikiTheme.good : metrics.healthScore >= 55 ? PocketWikiTheme.warn : PocketWikiTheme.bad)
                .lineLimit(1)
        }
    }

    private func pageList(_ pages: [WikiPage], meta: @escaping (WikiPage) -> String) -> some View {
        Group {
            if pages.isEmpty {
                Text("nada encontrado")
                    .foregroundStyle(PocketWikiTheme.muted)
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

struct DashboardActionTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(PocketWikiTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(PocketWikiTheme.bg3, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(PocketWikiTheme.border, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(PocketWikiTheme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(PocketWikiTheme.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(12)
            .background((isHovering ? PocketWikiTheme.accent.opacity(0.10) : PocketWikiTheme.bg2.opacity(0.68)), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? PocketWikiTheme.accent.opacity(0.7) : PocketWikiTheme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
        if !page.missingLinks.isEmpty { return PocketWikiTheme.bad.opacity(0.75) }
        let value = density(page)
        if value >= 12 { return PocketWikiTheme.accent.opacity(0.82) }
        if value >= 5 { return PocketWikiTheme.accent2.opacity(0.72) }
        if value > 0 { return PocketWikiTheme.good.opacity(0.56) }
        return PocketWikiTheme.muted.opacity(0.25)
    }
}
