import SwiftUI

struct TimelineView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        let pages = WikiAnalytics.timelinePages(in: store.index)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Linha do tempo")
                    .font(.system(size: 34, weight: .heavy, design: .serif))
                    .foregroundStyle(PocketWikiTheme.text)
                Text("Ordenada por frontmatter `updated/date`, campos de data no texto ou data de modificacao do arquivo.")
                    .foregroundStyle(PocketWikiTheme.dim)

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(pages) { page in
                        Button {
                            store.selectPage(page.id)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: page.kind == .excalidraw ? "scribble.variable" : "doc.text")
                                    .foregroundStyle(PocketWikiTheme.accent)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(PocketFormatters.date(page.updatedAt))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(PocketWikiTheme.accent)
                                    Text(page.title)
                                        .font(.headline)
                                        .foregroundStyle(PocketWikiTheme.text)
                                    if !page.summary.isEmpty {
                                        Text(page.summary)
                                            .font(.callout)
                                            .foregroundStyle(PocketWikiTheme.dim)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(PocketWikiTheme.panel.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(PocketWikiTheme.border, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(PocketWikiTheme.appBackground)
    }
}
