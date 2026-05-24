import SwiftUI

struct SidebarView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        let sections = WikiSidebarExplorer.sections(index: store.index, selectedPageID: store.selectedPageID, query: store.searchText)

        VStack(spacing: 0) {
            header
                .padding()

            List {
                if !sections.isEmpty {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                sidebarItemRow(item)
                            }
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

    private func sidebarItemRow(_ item: WikiSidebarItem) -> some View {
        Button {
            switch item.kind {
            case .page(let id):
                store.selectPage(id, tab: store.selectedTab == .map ? .map : .reader)
            case .tag(let tag):
                store.selectTag(tag)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .foregroundStyle(item.isWarning ? PocketWikiTheme.bad : PocketWikiTheme.dim)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .foregroundStyle(PocketWikiTheme.text)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(PocketWikiTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(for: item))
    }

    private func rowBackground(for item: WikiSidebarItem) -> Color {
        guard case .page(let id) = item.kind, id == store.selectedPageID else {
            return Color.clear
        }
        return PocketWikiTheme.accent.opacity(0.14)
    }
}
