import SwiftUI

struct DetailContainerView: View {
    @Bindable var store: WikiAppStore
    @SceneStorage("PocketWikiMac.inspectorDrawerPresented") private var inspectorDrawerPresented = false

    private let inlineInspectorBreakpoint: CGFloat = 1080
    private let inlineInspectorWidth: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            let isCompactInspector = proxy.size.width < inlineInspectorBreakpoint

            VStack(spacing: 0) {
                topBar(isCompactInspector: isCompactInspector)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(PocketWikiTheme.bg.opacity(0.9))

                Rectangle()
                    .fill(PocketWikiTheme.border)
                    .frame(height: 1)

                if store.isLoading {
                    ProgressView(store.statusMessage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.index.pages.isEmpty {
                    WelcomeView(store: store)
                } else {
                    content(isCompactInspector: isCompactInspector, availableWidth: proxy.size.width)
                }
            }
            .background(PocketWikiTheme.appBackground)
            .onChange(of: isCompactInspector) { _, compact in
                if !compact {
                    inspectorDrawerPresented = false
                }
            }
            .onChange(of: store.selectedPageID) { _, _ in
                inspectorDrawerPresented = false
            }
        }
    }

    private func topBar(isCompactInspector: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                tabPicker
                    .frame(maxWidth: 560)

                Spacer(minLength: 12)

                inspectorButton(isCompactInspector: isCompactInspector, showsText: true)
            }

            HStack(spacing: 10) {
                tabMenu

                Spacer(minLength: 8)

                inspectorButton(isCompactInspector: isCompactInspector, showsText: false)
            }
        }
        .foregroundStyle(PocketWikiTheme.text)
    }

    private var tabPicker: some View {
        Picker("", selection: $store.selectedTab) {
            ForEach(WikiTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var tabMenu: some View {
        Menu {
            Picker("Aba", selection: $store.selectedTab) {
                ForEach(WikiTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
        } label: {
            Label(store.selectedTab.title, systemImage: store.selectedTab.systemImage)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 8))
    }

    @ViewBuilder
    private func inspectorButton(isCompactInspector: Bool, showsText: Bool) -> some View {
        if isCompactInspector, store.selectedPage != nil {
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
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 8))
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

                if !isCompactInspector, let page = store.selectedPage {
                    Rectangle()
                        .fill(PocketWikiTheme.border)
                        .frame(width: 1)
                    InspectorView(store: store, page: page)
                        .frame(width: inlineInspectorWidth)
                }
            }

            if isCompactInspector, inspectorDrawerPresented, let page = store.selectedPage {
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

    @ViewBuilder
    private var selectedTabView: some View {
        switch store.selectedTab {
        case .dashboard:
            DashboardView(store: store)
        case .reader:
            ReaderView(store: store)
        case .excalidraw:
            ExcalidrawView(store: store)
        case .health:
            HealthView(store: store)
        case .timeline:
            TimelineView(store: store)
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
            .background(PocketWikiTheme.bg2.opacity(0.98))

            Rectangle()
                .fill(PocketWikiTheme.border)
                .frame(height: 1)

            InspectorView(store: store, page: page, showsHeader: false)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(PocketWikiTheme.bg2)
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
