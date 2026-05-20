import SwiftUI

struct SearchPaletteView: View {
    @Bindable var store: WikiAppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Digite para abrir pagina, path, resumo ou tag...", text: $store.searchText)
                    .textFieldStyle(.plain)
                Button("Fechar") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            List(store.searchResults) { result in
                Button {
                    store.selectPage(result.pageID)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .lineLimit(1)
                            Text(result.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(result.reason)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
