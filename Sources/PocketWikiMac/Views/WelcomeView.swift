import SwiftUI

struct WelcomeView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        VStack(spacing: 18) {
            BrandLogoView(size: 128)

            Text("PocketWiki nativo")
                .font(.system(size: 42, weight: .heavy, design: .serif))
                .foregroundStyle(PocketWikiTheme.text)

            Text("Abra a raiz da wiki. O app lê Markdown e Excalidraw direto do filesystem local, monta índice, backlinks, saúde e timeline sem depender do servidor Node.")
                .foregroundStyle(PocketWikiTheme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            Button {
                Task { await store.openFolder() }
            } label: {
                Label("Abrir pasta da wiki", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .tint(PocketWikiTheme.accent)
            .controlSize(.large)

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(PocketWikiTheme.bad)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
        }
        .padding(34)
        .pocketWikiCard(hero: true)
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PocketWikiTheme.appBackground)
    }
}
