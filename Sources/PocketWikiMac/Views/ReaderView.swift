import MarkdownUI
import SwiftUI

struct ReaderView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        guard let page = store.selectedPage else {
            return AnyView(EmptyStateView(
                title: "Nenhuma pagina selecionada",
                message: "Escolha uma pagina na sidebar ou use a busca.",
                systemImage: "doc.text.magnifyingglass"
            ))
        }

        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(page)
                    markdown(page)
                    linkSections(page)
                }
                .padding(24)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .environment(\.openURL, OpenURLAction { url in
                handleOpenURL(url)
            })
            .background(PocketWikiTheme.appBackground)
        )
    }

    private func header(_ page: WikiPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(page.path)
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.muted)
                .textSelection(.enabled)

            Text(page.title)
                .font(.system(size: 38, weight: .heavy, design: .serif))
                .foregroundStyle(PocketWikiTheme.text)
                .lineLimit(3)
                .textSelection(.enabled)

            FlowLayout(spacing: 8) {
                Label("\(page.wordCount) palavras", systemImage: "text.word.spacing")
                Label("\(page.readingMinutes) min", systemImage: "clock")
                Label("\(page.backlinks.count) backlinks", systemImage: "arrowshape.turn.up.left")
                Label("\(page.outlinks.count) links", systemImage: "link")
                Label(PocketFormatters.date(page.updatedAt), systemImage: "calendar")
                if !page.missingLinks.isEmpty {
                    Label("\(page.missingLinks.count) ausentes", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(PocketWikiTheme.bad)
                }
            }
            .font(.caption)
            .foregroundStyle(PocketWikiTheme.dim)

            if !page.tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(page.tags, id: \.self) { tag in
                        Button("#\(tag)") {
                            store.selectTag(tag)
                        }
                        .buttonStyle(.bordered)
                        .tint(PocketWikiTheme.accent2)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PocketWikiTheme.border)
                .frame(height: 1)
        }
    }

    private func markdown(_ page: WikiPage) -> some View {
        Markdown(WikiMarkdownFormatter.markdownForDisplay(page: page, index: store.index))
            .markdownTheme(.pocketWiki)
            .textSelection(.enabled)
            .tint(PocketWikiTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkSections(_ page: WikiPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !page.missingLinks.isEmpty {
                SectionCard("Links ausentes", subtitle: "\(page.missingLinks.count)", systemImage: "exclamationmark.triangle") {
                    FlowLayout(spacing: 8) {
                        ForEach(page.missingLinks) { link in
                            Text(link.label)
                                .font(.caption)
                                .foregroundStyle(PocketWikiTheme.bad)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(PocketWikiTheme.bg3.opacity(0.72), in: Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(PocketWikiTheme.bad.opacity(0.45), lineWidth: 1)
                                }
                        }
                    }
                }
            }

            if page.kind == .excalidraw {
                Button {
                    store.selectedTab = .excalidraw
                } label: {
                    Label("Ver Excalidraw textual", systemImage: "scribble.variable")
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketWikiTheme.accent)
                .buttonBorderShape(.roundedRectangle(radius: 8))
            }
        }
    }

    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme?.lowercased() == "pocketwiki", url.host == "page" else {
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else {
                return .handled
            }
            return .systemAction
        }
        let id = url.path.dropFirst().removingPercentEncoding ?? String(url.path.dropFirst())
        store.selectPage(id, tab: .reader)
        return .handled
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: width, height: origin.y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
