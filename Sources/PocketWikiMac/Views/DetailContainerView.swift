import SwiftUI

struct DetailContainerView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            if store.isLoading {
                ProgressView(store.statusMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.index.pages.isEmpty {
                WelcomeView(store: store)
            } else {
                content
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("Tela", selection: $store.selectedTab) {
                ForEach(WikiTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560)

            Spacer()

            Button {
                Task { await store.reloadCurrentSource() }
            } label: {
                Label("Recarregar", systemImage: "arrow.clockwise")
            }
            .disabled(store.index.pages.isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 0) {
            Group {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let page = store.selectedPage {
                Divider()
                InspectorView(store: store, page: page)
                    .frame(width: 300)
            }
        }
    }
}
