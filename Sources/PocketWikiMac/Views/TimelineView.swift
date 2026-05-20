import SwiftUI

struct TimelineView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        let pages = WikiAnalytics.timelinePages(in: store.index)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Linha do tempo")
                    .font(.largeTitle.bold())
                Text("Ordenada por frontmatter `updated/date`, campos de data no texto ou data de modificacao do arquivo.")
                    .foregroundStyle(.secondary)

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(pages) { page in
                        Button {
                            store.selectPage(page.id)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: page.kind == .excalidraw ? "scribble.variable" : "doc.text")
                                    .foregroundStyle(.tint)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(PocketFormatters.date(page.updatedAt))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(page.title)
                                        .font(.headline)
                                    if !page.summary.isEmpty {
                                        Text(page.summary)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
