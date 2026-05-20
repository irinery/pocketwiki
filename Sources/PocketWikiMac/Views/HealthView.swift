import SwiftUI

struct HealthView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        let metrics = WikiAnalytics.metrics(for: store.index)
        let issues = WikiAnalytics.healthIssues(for: store.index)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saude da wiki: \(metrics.healthScore)/100")
                        .font(.largeTitle.bold())
                    Text("Nota heuristica para priorizar links quebrados, paginas isoladas, orfas, sem resumo e conteudo antigo.")
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        MetricTile(title: "Links quebrados", value: "\(metrics.missingDestinations)", systemImage: "exclamationmark.triangle")
                        MetricTile(title: "Orfaos", value: "\(WikiAnalytics.orphanPages(in: store.index).count)", systemImage: "link.badge.plus")
                        MetricTile(title: "Sem resumo", value: "\(store.index.pages.filter { $0.summary.isEmpty }.count)", systemImage: "text.alignleft")
                        MetricTile(title: "Isoladas", value: "\(WikiAnalytics.isolatedPages(in: store.index).count)", systemImage: "circle.dashed")
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                SectionCard("Revisao", subtitle: "fila acionavel", systemImage: "checklist") {
                    if issues.isEmpty {
                        Text("Nada critico encontrado. Mantem revisao periodica de paginas antigas e hubs.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(issues) { issue in
                                issueView(issue)
                            }
                        }
                    }
                }

                if !store.index.loadIssues.isEmpty {
                    SectionCard("Falhas de leitura", subtitle: "\(store.index.loadIssues.count)", systemImage: "exclamationmark.octagon") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.index.loadIssues, id: \.self) { issue in
                                Text(issue)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func issueView(_ issue: WikiHealthIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(issue.title)
                    .font(.headline)
                Spacer()
                Text(issue.priority.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(color(issue.priority))
            }

            Text(issue.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 8) {
                ForEach(issue.pageIDs, id: \.self) { id in
                    if let page = store.index.page(id: id) {
                        Button(page.title) {
                            store.selectPage(page.id)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(_ priority: WikiHealthIssue.Priority) -> Color {
        switch priority {
        case .high: .red
        case .medium: .orange
        case .low: .secondary
        }
    }
}
