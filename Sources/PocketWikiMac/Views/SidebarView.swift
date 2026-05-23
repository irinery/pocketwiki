import SwiftUI

struct SidebarView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()

            List(selection: $store.selectedPageID) {
                if !store.index.pages.isEmpty {
                    Section("Paginas") {
                        ForEach(store.filteredPages) { page in
                            sidebarRow(page)
                                .tag(page.id as String?)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .searchable(text: $store.searchText, placement: .sidebar, prompt: "Buscar / filtrar")
        }
        .background(PocketWikiTheme.bg2)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await store.openFolder() }
                } label: {
                    Label("Abrir pasta", systemImage: "folder")
                }

                Button {
                    store.showSearchPalette = true
                } label: {
                    Label("Busca", systemImage: "command")
                }
            }
        }
        .onChange(of: store.selectedPageID) { _, newValue in
            if newValue != nil, store.selectedTab == .dashboard {
                store.selectedTab = .reader
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrandLogoView(size: 74)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PocketWiki")
                        .font(.system(size: 20, weight: .heavy, design: .serif))
                        .foregroundStyle(PocketWikiTheme.text)
                    Text(store.index.sourceName)
                        .font(.caption.monospaced())
                        .foregroundStyle(PocketWikiTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
            }

            Button {
                Task { await store.openFolder() }
            } label: {
                Label("Abrir pasta da wiki", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketWikiTheme.accent)
            .buttonBorderShape(.roundedRectangle(radius: 8))

            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(PocketWikiTheme.muted)
                .lineLimit(2)
        }
        .padding(12)
        .background(PocketWikiTheme.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(PocketWikiTheme.border, lineWidth: 1)
        }
    }

    private func sidebarRow(_ page: WikiPage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: page.kind == .excalidraw ? "scribble.variable" : "doc.text")
                .foregroundStyle(page.missingLinks.isEmpty ? PocketWikiTheme.dim : PocketWikiTheme.bad)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .foregroundStyle(PocketWikiTheme.text)
                    .lineLimit(1)
                Text(page.path)
                    .font(.caption)
                    .foregroundStyle(PocketWikiTheme.muted)
                    .lineLimit(1)
            }
        }
    }
}
