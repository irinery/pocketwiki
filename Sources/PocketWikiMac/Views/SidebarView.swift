import SwiftUI

struct SidebarView: View {
    @Bindable var store: WikiAppStore
    @Bindable var updater: CanonicalUpdater

    var body: some View {
        let sections = WikiSidebarExplorer.sections(index: store.index, selectedPageID: store.selectedPageID, query: store.searchText)

        VStack(spacing: 0) {
            header

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

            if updater.availableRelease != nil {
                updateFooter
            }
        }
        .background(.ultraThinMaterial)
    }

    private var updateFooter: some View {
        CanonicalUpdateButton(updater: updater)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PocketWikiTheme.border)
                    .frame(height: 1)
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BrandLogoView(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PocketWiki")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(PocketWikiTheme.text)
                    Text(sourceSummary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.index.pages.isEmpty ? PocketWikiTheme.muted : PocketWikiTheme.accent)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.leading, 62)

            Button {
                Task { await store.openFolder() }
            } label: {
                Label("Abrir pasta da wiki", systemImage: "folder.badge.plus")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PocketWikiTheme.text)
            .pocketWikiGlass(cornerRadius: 14, tint: PocketWikiTheme.accent.opacity(0.24), interactive: true)

            searchField
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PocketWikiTheme.border)
                .frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PocketWikiTheme.muted)

            TextField("Buscar / filtrar", text: $store.searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(PocketWikiTheme.text)

            Button {
                store.showSearchPalette = true
            } label: {
                Text("⌘K")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(PocketWikiTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(PocketWikiTheme.bg.opacity(0.36), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Abrir busca global")
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .pocketWikiSurface(cornerRadius: 14)
    }

    private var sourceSummary: String {
        guard !store.index.pages.isEmpty else { return "nenhuma wiki carregada" }
        let drawings = store.index.pages.filter { $0.kind == .excalidraw }.count
        return "\(store.index.pages.count) páginas · \(drawings) desenhos"
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
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(rowBackground(for: item), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
    }

    private func rowBackground(for item: WikiSidebarItem) -> Color {
        guard case .page(let id) = item.kind, id == store.selectedPageID else {
            return Color.clear
        }
        return PocketWikiTheme.accent.opacity(0.16)
    }
}
