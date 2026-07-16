import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: WikiAppStore
    @Bindable var updater: CanonicalUpdater
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        ZStack {
            PocketWikiAmbientBackground()

            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(store: store)
                    .navigationSplitViewColumnWidth(min: 248, ideal: 292, max: 360)
            } detail: {
                DetailContainerView(store: store, columnVisibility: $columnVisibility)
            }
            .background(Color.clear)
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(PocketWikiWindowToolbarCleaner().frame(width: 0, height: 0))
        .tint(PocketWikiTheme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $store.showSearchPalette) {
            SearchPaletteView(store: store)
                .frame(minWidth: 620, minHeight: 520)
                .presentationBackground(.ultraThinMaterial)
        }
        .overlay(alignment: .topTrailing) {
            CanonicalUpdateButton(updater: updater)
                .padding(.top, 9)
                .padding(.trailing, 14)
        }
        .task {
            await updater.checkForUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await updater.checkForUpdates() }
        }
    }
}

private struct PocketWikiWindowToolbarCleaner: NSViewRepresentable {
    func makeNSView(context: Context) -> PocketWikiToolbarHostView {
        PocketWikiToolbarHostView()
    }

    func updateNSView(_ nsView: PocketWikiToolbarHostView, context: Context) {
        nsView.removeAutomaticSidebarToggle()
    }
}

@MainActor
private final class PocketWikiToolbarHostView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)

        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidUpdate(_:)),
                name: NSWindow.didUpdateNotification,
                object: window
            )
        }

        removeAutomaticSidebarToggle()
        Task { @MainActor [weak self] in
            for delay in [100, 400, 900] {
                try? await Task.sleep(for: .milliseconds(delay))
                self?.removeAutomaticSidebarToggle()
            }
        }
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.removeAutomaticSidebarToggle()
        }
    }

    func removeAutomaticSidebarToggle() {
        guard let toolbar = window?.toolbar else { return }
        while let index = toolbar.items.firstIndex(where: { item in
            item.itemIdentifier == .toggleSidebar
                || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("sidebar")
                || item.action == #selector(NSSplitViewController.toggleSidebar(_:))
        }) {
            toolbar.removeItem(at: index)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
