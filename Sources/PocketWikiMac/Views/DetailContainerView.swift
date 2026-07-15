import SwiftUI

struct DetailContainerView: View {
    @Bindable var store: WikiAppStore
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @SceneStorage("PocketWikiMac.inspectorDrawerPresented") private var inspectorDrawerPresented = false

    private let inlineInspectorBreakpoint: CGFloat = 1080
    private let inlineInspectorWidth: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            let isCompactInspector = proxy.size.width < inlineInspectorBreakpoint
            let usesCompactTabs = proxy.size.width < 980
            let showsBreadcrumb = proxy.size.width >= 1040

            VStack(spacing: 0) {
                topBar(
                    isCompactInspector: isCompactInspector,
                    usesCompactTabs: usesCompactTabs,
                    showsBreadcrumb: showsBreadcrumb
                )
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .pocketWikiGlass(cornerRadius: 20)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                if store.isLoading {
                    ProgressView(store.statusMessage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.index.pages.isEmpty {
                    WelcomeView(store: store)
                } else {
                    content(isCompactInspector: isCompactInspector, availableWidth: proxy.size.width)
                }
            }
            .background(PocketWikiAmbientBackground())
            .onChange(of: isCompactInspector) { _, compact in
                if !compact {
                    inspectorDrawerPresented = false
                }
            }
            .onChange(of: store.selectedPageID) { _, _ in
                inspectorDrawerPresented = false
            }
            .onChange(of: store.selectedTab) { _, _ in
                if !showsPageInspector {
                    inspectorDrawerPresented = false
                }
            }
        }
    }

    private func topBar(isCompactInspector: Bool, usesCompactTabs: Bool, showsBreadcrumb: Bool) -> some View {
        HStack(spacing: 10) {
            if columnVisibility == .detailOnly {
                Color.clear
                    .frame(width: 54, height: 1)
            }

            sidebarButton

            if showsBreadcrumb {
                breadcrumb
                Spacer(minLength: 8)
            }

            WikiTabStrip(selection: $store.selectedTab, showsLabels: !usesCompactTabs)
                .layoutPriority(2)

            if !showsBreadcrumb {
                Spacer(minLength: 8)
            }

            ServerStatusPill(store: store, showsDetail: false)
            inspectorButton(isCompactInspector: isCompactInspector, showsText: false)
        }
        .foregroundStyle(PocketWikiTheme.text)
    }

    private var sidebarButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left")
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .pocketWikiSurface(cornerRadius: 12, tint: PocketWikiTheme.accent2)
        .help(columnVisibility == .detailOnly ? "Abrir barra lateral" : "Fechar barra lateral")
    }

    private var breadcrumb: some View {
        HStack(spacing: 5) {
            Text(store.index.sourceName)
                .foregroundStyle(PocketWikiTheme.accent)
                .fontWeight(.semibold)

            Text("/")
                .foregroundStyle(PocketWikiTheme.muted)

            Text(store.selectedPage?.path ?? store.selectedTab.title)
                .foregroundStyle(PocketWikiTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .frame(minWidth: 100, maxWidth: 190, alignment: .leading)
    }

    @ViewBuilder
    private func inspectorButton(isCompactInspector: Bool, showsText: Bool) -> some View {
        if isCompactInspector, showsPageInspector {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    inspectorDrawerPresented.toggle()
                }
            } label: {
                if showsText {
                    Label("Info", systemImage: inspectorDrawerPresented ? "sidebar.right" : "info.circle")
                } else {
                    Image(systemName: inspectorDrawerPresented ? "sidebar.right" : "info.circle")
                }
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .pocketWikiGlass(cornerRadius: 13, interactive: true)
            .controlSize(.small)
            .help(inspectorDrawerPresented ? "Fechar informacoes" : "Abrir informacoes")
        }
    }

    @ViewBuilder
    private func content(isCompactInspector: Bool, availableWidth: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                selectedTabView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isCompactInspector, showsPageInspector, let page = store.selectedPage {
                    Rectangle()
                        .fill(PocketWikiTheme.border)
                        .frame(width: 1)
                    InspectorView(store: store, page: page)
                        .frame(width: inlineInspectorWidth)
                }
            }

            if isCompactInspector, inspectorDrawerPresented, showsPageInspector, let page = store.selectedPage {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.22)) {
                            inspectorDrawerPresented = false
                        }
                    }
                    .transition(.opacity)

                inspectorDrawer(page: page, width: drawerWidth(for: availableWidth))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.22), value: isCompactInspector)
        .animation(.snappy(duration: 0.22), value: inspectorDrawerPresented)
    }

    private var showsPageInspector: Bool {
        guard store.selectedPage != nil else { return false }
        switch store.selectedTab {
        case .reader, .excalidraw, .map:
            return true
        case .dashboard, .localAI, .health, .timeline, .server:
            return false
        }
    }

    @ViewBuilder
    private var selectedTabView: some View {
        switch store.selectedTab {
        case .dashboard:
            DashboardView(store: store)
        case .reader:
            ReaderView(store: store)
        case .excalidraw:
            ExcalidrawView(store: store)
        case .map:
            MapView(store: store)
        case .health:
            HealthView(store: store)
        case .timeline:
            TimelineView(store: store)
        case .localAI:
            LocalAIView(store: store)
        case .server:
            ServerView(store: store)
        }
    }

    private func inspectorDrawer(page: WikiPage, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Informacoes", systemImage: "info.circle")
                    .font(.headline)
                    .foregroundStyle(PocketWikiTheme.text)

                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        inspectorDrawerPresented = false
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Fechar informacoes")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Rectangle()
                .fill(PocketWikiTheme.border)
                .frame(height: 1)

            InspectorView(store: store, page: page, showsHeader: false)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PocketWikiTheme.border)
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 28, x: -14, y: 0)
    }

    private func drawerWidth(for availableWidth: CGFloat) -> CGFloat {
        min(390, max(300, availableWidth * 0.86))
    }
}
