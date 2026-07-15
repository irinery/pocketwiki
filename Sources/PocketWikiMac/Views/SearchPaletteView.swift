import SwiftUI

struct SearchPaletteView: View {
    @Bindable var store: WikiAppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(PocketWikiTheme.accent)
                TextField("Digite para abrir pagina, path, resumo ou tag...", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(PocketWikiTheme.text)
                Button("Fechar") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .pocketWikiGlass(cornerRadius: 18, interactive: true)
            .padding(12)

            List(store.searchResults) { result in
                Button {
                    store.selectPage(result.pageID)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(PocketWikiTheme.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .foregroundStyle(PocketWikiTheme.text)
                                .lineLimit(1)
                            Text(result.path)
                                .font(.caption)
                                .foregroundStyle(PocketWikiTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(result.reason)
                            .font(.caption.monospaced())
                            .foregroundStyle(PocketWikiTheme.accent2)
                    }
                }
                .buttonStyle(.plain)
            }
            .scrollContentBackground(.hidden)
        }
        .background(PocketWikiAmbientBackground())
    }
}
