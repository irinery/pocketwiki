import SwiftUI

struct WelcomeView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        VStack(spacing: 22) {
            BrandLogoView(size: 112)

            VStack(spacing: 10) {
                Text("Sua wiki, em perspectiva.")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .tracking(-1.4)
                    .foregroundStyle(PocketWikiTheme.text)

                Text("Markdown e Excalidraw locais viram leitura, conexões, saúde, timeline e contexto para IA — sem tirar o conteúdo da sua máquina.")
                    .font(.title3)
                    .foregroundStyle(PocketWikiTheme.dim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    feature("Leitura local", icon: "lock.shield")
                    feature("Mapa vivo", icon: "point.3.connected.trianglepath.dotted")
                    feature("IA contextual", icon: "sparkles")
                }

                VStack(spacing: 8) {
                    feature("Leitura local", icon: "lock.shield")
                    feature("Mapa vivo", icon: "point.3.connected.trianglepath.dotted")
                    feature("IA contextual", icon: "sparkles")
                }
            }

            Button {
                Task { await store.openFolder() }
            } label: {
                Label("Abrir pasta da wiki", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .controlSize(.large)
            .font(.headline)
            .foregroundStyle(PocketWikiTheme.text)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .pocketWikiGlass(cornerRadius: 18, tint: PocketWikiTheme.accent.opacity(0.26), interactive: true)

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(PocketWikiTheme.bad)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
        }
        .padding(42)
        .pocketWikiCard(hero: true)
        .frame(maxWidth: 860)
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PocketWikiAmbientBackground())
    }

    private func feature(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(PocketWikiTheme.dim)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .pocketWikiSurface(cornerRadius: 14)
    }
}
