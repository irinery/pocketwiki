import SwiftUI

struct MapView: View {
    @Bindable var store: WikiAppStore
    @State private var graphScope: WikiGraphScope = .local
    @State private var graphDepth = 1.0
    @State private var graphSearch = ""
    private let maxVisibleGraphNodes = 500

    var body: some View {
        let page = store.selectedPage
        let graph = WikiGraphSnapshot.build(index: store.index, selectedPageID: store.selectedPageID)
        let filterConfig = FilterConfig(
            scope: graphScope,
            depth: Int(graphDepth),
            selectedNodeID: store.selectedPageID,
            searchTerm: graphSearch
        )
        let filteredGraph = graph.filtered(using: filterConfig, maxNodes: maxVisibleGraphNodes)
        let hubs = store.index.pages.sorted { $0.connectivityScore > $1.connectivityScore }.prefix(10)
        let missing = store.index.pages.filter { !$0.missingLinks.isEmpty }.prefix(10)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(page, graph: graph, filteredGraph: filteredGraph)

                WikiGraphPanel(
                    graph: graph,
                    filteredGraph: filteredGraph,
                    filterConfig: filterConfig,
                    selectedPageID: store.selectedPageID,
                    scope: $graphScope,
                    depth: $graphDepth,
                    search: $graphSearch
                ) { pageID in
                    store.selectPage(pageID, tab: .map)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], alignment: .leading, spacing: 16) {
                    SectionCard("Pagina atual", subtitle: page?.title ?? "nenhuma", systemImage: "scope") {
                        if let page {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(page.summary.isEmpty ? page.path : page.summary)
                                    .foregroundStyle(PocketWikiTheme.dim)
                                    .lineLimit(4)
                                relationStats(page)
                            }
                        } else {
                            Text("Selecione uma pagina para ver o mapa textual.")
                                .foregroundStyle(PocketWikiTheme.muted)
                        }
                    }

                    SectionCard("Backlinks", subtitle: "\(page?.backlinks.count ?? 0)", systemImage: "arrow.uturn.backward") {
                        pageList(pages(for: page?.backlinks ?? []), empty: "sem backlinks")
                    }

                    SectionCard("Outlinks", subtitle: "\(page?.outlinks.count ?? 0)", systemImage: "arrow.uturn.forward") {
                        pageList(pages(for: page?.outlinks.compactMap(\.resolvedPageID) ?? []), empty: "sem outlinks resolvidos")
                    }

                    SectionCard("Hubs", subtitle: "\(hubs.count)", systemImage: "point.3.connected.trianglepath.dotted") {
                        pageList(Array(hubs), empty: "sem hubs")
                    }

                    SectionCard("Links ausentes", subtitle: "\(missing.count)", systemImage: "exclamationmark.triangle") {
                        pageList(Array(missing), empty: "sem links ausentes")
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 1360, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(PocketWikiTheme.appBackground)
    }

    private func header(_ page: WikiPage?, graph: WikiGraphSnapshot, filteredGraph: FilteredSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                headerIntro(page)
                Spacer()
                headerMetrics(graph, filteredGraph: filteredGraph)
            }

            VStack(alignment: .leading, spacing: 14) {
                headerIntro(page)
                headerMetrics(graph, filteredGraph: filteredGraph)
            }
        }
        .padding(18)
        .pocketWikiCard(hero: true)
    }

    private func headerIntro(_ page: WikiPage?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            PocketWikiIcon(kind: .map, size: 36)
                .foregroundStyle(PocketWikiTheme.accent)
                .frame(width: 52, height: 52)
                .pocketWikiSurface(cornerRadius: 16, tint: PocketWikiTheme.accent2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Mapa")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(PocketWikiTheme.text)
                Text(page.map { "Grafo de relacoes de \($0.title)" } ?? "Grafo de interconexoes entre arquivos da wiki.")
                    .foregroundStyle(PocketWikiTheme.dim)
                    .lineLimit(2)
            }
        }
    }

    private func headerMetrics(_ graph: WikiGraphSnapshot, filteredGraph: FilteredSnapshot) -> some View {
        HStack(spacing: 10) {
            MetricTile(title: "Nos", value: "\(filteredGraph.nodes.count)", systemImage: "circle.grid.cross")
                .frame(width: 132)
            MetricTile(title: "Links", value: "\(filteredGraph.edges.count)", systemImage: "arrow.right")
                .frame(width: 132)
            if graph.truncated {
                MetricTile(title: "Limite", value: "ativo", systemImage: "scissors")
                    .frame(width: 132)
            }
        }
    }

    private func relationStats(_ page: WikiPage) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
            MetricTile(title: "Backlinks", value: "\(page.backlinks.count)", systemImage: "arrow.uturn.backward")
            MetricTile(title: "Outlinks", value: "\(page.outlinks.count)", systemImage: "arrow.uturn.forward")
            MetricTile(title: "Ausentes", value: "\(page.missingLinks.count)", systemImage: "exclamationmark.triangle")
        }
    }

    private func pages(for ids: [String]) -> [WikiPage] {
        ids.compactMap { store.index.page(id: $0) }
    }

    private func pageList(_ pages: [WikiPage], empty: String) -> some View {
        Group {
            if pages.isEmpty {
                Text(empty)
                    .foregroundStyle(PocketWikiTheme.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pages) { page in
                        PageListButton(page: page, meta: page.folder.isEmpty ? page.path : page.folder) {
                            store.selectPage(page.id, tab: .map)
                        }
                    }
                }
            }
        }
    }
}
