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
            .searchable(text: $store.searchText, placement: .sidebar, prompt: "Buscar / filtrar")
        }
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
                Image(systemName: "books.vertical")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PocketWiki")
                        .font(.headline)
                    Text(store.index.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func sidebarRow(_ page: WikiPage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: page.kind == .excalidraw ? "scribble.variable" : "doc.text")
                .foregroundStyle(page.missingLinks.isEmpty ? Color.secondary : Color.red)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .lineLimit(1)
                Text(page.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
