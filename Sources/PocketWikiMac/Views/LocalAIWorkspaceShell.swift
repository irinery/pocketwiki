import SwiftUI

enum LocalAIWorkspaceLayoutMode: Equatable {
    case regular
    case compact

    init(width: CGFloat) {
        self = width < 900 ? .compact : .regular
    }

    var contentPadding: CGFloat {
        switch self {
        case .regular:
            22
        case .compact:
            10
        }
    }

    var showsHero: Bool {
        self == .regular
    }
}

struct LocalAIWorkspaceShell<Hero: View, Chat: View, SideRail: View, SidePanel: View>: View {
    let mode: LocalAIWorkspaceLayoutMode
    let isSidePanelOpen: Bool
    let sidePanelWidth: CGFloat
    @ViewBuilder let hero: Hero
    @ViewBuilder let chat: Chat
    @ViewBuilder let sideRail: SideRail
    @ViewBuilder let sidePanel: SidePanel

    init(
        mode: LocalAIWorkspaceLayoutMode,
        isSidePanelOpen: Bool,
        sidePanelWidth: CGFloat = 330,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder chat: () -> Chat,
        @ViewBuilder sideRail: () -> SideRail,
        @ViewBuilder sidePanel: () -> SidePanel
    ) {
        self.mode = mode
        self.isSidePanelOpen = isSidePanelOpen
        self.sidePanelWidth = sidePanelWidth
        self.hero = hero()
        self.chat = chat()
        self.sideRail = sideRail()
        self.sidePanel = sidePanel()
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: mode.showsHero ? 16 : 0) {
                if mode.showsHero {
                    hero
                }

                switch mode {
                case .regular:
                    regularLayout
                case .compact:
                    compactLayout(maxWidth: proxy.size.width)
                }
            }
            .padding(mode.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PocketWikiTheme.appBackground)
        }
    }

    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            chat
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .top, spacing: 12) {
                sideRail

                if isSidePanelOpen {
                    sidePanel
                        .frame(width: sidePanelWidth)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactLayout(maxWidth: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            chat
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .trailing, spacing: 8) {
                sideRail

                if isSidePanelOpen {
                    sidePanel
                        .frame(width: min(sidePanelWidth, max(280, maxWidth - 28)))
                        .shadow(color: .black.opacity(0.34), radius: 22, x: 0, y: 12)
                }
            }
            .padding(8)
            .zIndex(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LocalAIHeroView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IA local da wiki")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .tracking(-0.7)
                .foregroundStyle(PocketWikiTheme.text)
                .lineLimit(1)

            Text("Provider configurado no MiddlewareAuth; resposta sempre governada pelo PocketKernel Harness.")
                .font(.body)
                .foregroundStyle(PocketWikiTheme.dim)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pocketWikiCard(hero: true)
    }
}
