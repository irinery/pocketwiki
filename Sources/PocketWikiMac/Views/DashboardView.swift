import SwiftUI

struct DashboardView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        let metrics = WikiAnalytics.metrics(for: store.index)
        let hubs = store.index.pages.sorted { $0.connectivityScore > $1.connectivityScore }.filter { $0.connectivityScore >= 4 }
        let orphans = WikiAnalytics.orphanPages(in: store.index)
        let recent = Array(WikiAnalytics.timelinePages(in: store.index).prefix(8))
        let tags = Array(store.index.tagIndex.sorted { $0.value.count > $1.value.count }.prefix(18))

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dashboardHeader(metrics)
                dashboardSections(hubs: hubs, orphans: orphans, recent: recent, tags: tags)
            }
            .padding(22)
            .frame(maxWidth: 1360, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(PocketWikiTheme.appBackground)
    }

    private func dashboardHeader(_ metrics: WikiDashboardMetrics) -> some View {
        hero(metrics)
    }

    private func dashboardSections(hubs: [WikiPage], orphans: [WikiPage], recent: [WikiPage], tags: [(key: String, value: [String])]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            densitySection()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        recentSection(recent)
                        hubsSection(hubs)
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 16) {
                        missingLinksSection()
                        orphansSection(orphans)
                        tagsSection(tags)
                    }
                    .frame(minWidth: 360, maxWidth: 440, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 16) {
                    recentSection(recent)
                    missingLinksSection()
                    hubsSection(hubs)
                    orphansSection(orphans)
                    tagsSection(tags)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func densitySection() -> some View {
        SectionCard("Densidade", subtitle: "links por nota", systemImage: "square.grid.3x3") {
            DensityMiniMap(pages: store.index.pages) { id in
                store.selectPage(id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func recentSection(_ recent: [WikiPage]) -> some View {
        SectionCard("Recentes", subtitle: "por data", systemImage: "clock") {
            pageList(recent, meta: { PocketFormatters.date($0.updatedAt) })
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func hubsSection(_ hubs: [WikiPage]) -> some View {
        SectionCard("Hubs", subtitle: "\(hubs.count)", systemImage: "point.3.connected.trianglepath.dotted") {
            pageList(Array(hubs.prefix(8)), meta: { "\($0.backlinks.count) back · \($0.outlinks.count) out" })
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func missingLinksSection() -> some View {
        SectionCard("Links ausentes", subtitle: "\(store.index.missingLinks.count)", systemImage: "exclamationmark.triangle") {
            missingLinksList()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func orphansSection(_ orphans: [WikiPage]) -> some View {
        SectionCard("Orfaos", subtitle: "\(orphans.count)", systemImage: "link.badge.plus") {
            pageList(Array(orphans.prefix(8)), meta: { $0.folder.isEmpty ? "raiz" : $0.folder })
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tagsSection(_ tags: [(key: String, value: [String])]) -> some View {
        SectionCard("Tags", subtitle: "\(tags.count)", systemImage: "tag") {
            tagsList(tags)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(PocketWikiTheme.text)
                    .lineLimit(2)
                Text("Visão executiva da wiki local: densidade, hubs, buracos de documentação e páginas recentes.")
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

struct DensityMiniMap: View {
    let pages: [WikiPage]
    let open: (String) -> Void

    var body: some View {
        ScrollView {
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
        }
        .frame(minHeight: 118, maxHeight: 240, alignment: .top)
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
