import SwiftUI

struct WelcomeView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 54))
                .foregroundStyle(.tint)

            Text("PocketWiki nativo")
                .font(.largeTitle.bold())

            Text("Abra a raiz da wiki. O app lê Markdown e Excalidraw direto do filesystem local, monta índice, backlinks, saúde e timeline sem depender do servidor Node.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            Button {
                Task { await store.openFolder() }
            } label: {
                Label("Abrir pasta da wiki", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
