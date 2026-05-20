import SwiftUI

struct ContentView: View {
    @Bindable var store: WikiAppStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            DetailContainerView(store: store)
        }
        .sheet(isPresented: $store.showSearchPalette) {
            SearchPaletteView(store: store)
                .frame(minWidth: 620, minHeight: 520)
        }
    }
}
