import AppKit
import SwiftUI

@main
struct PocketWikiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WikiAppStore()
    @State private var updater = CanonicalUpdater()

    private var defaultWindowSize: (width: Double, height: Double) {
        ProcessInfo.processInfo.environment["NH_TEST_FIXTURE_PROVIDER_URL"] == nil
            ? (1440, 900)
            : (1000, 700)
    }

    var body: some Scene {
        WindowGroup("PocketWiki", id: "main") {
            ContentView(store: store, updater: updater)
                .frame(minWidth: 980, minHeight: 680)
                .task {
                    fitHarnessWindowIfNeeded()
                    appDelegate.terminationHandler = { [weak store] in
                        store?.shutdownManagedServices()
                    }
                    await store.restoreLastSource()
                    await store.bootstrapManagedServices()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir Pasta...") {
                    Task { await store.openFolder() }
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandMenu("PocketWiki") {
                Button("Recarregar Wiki") {
                    Task { await store.reloadCurrentSource() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Ir para Busca") {
                    store.showSearchPalette = true
                }
                .keyboardShortcut("k", modifiers: [.command])

                Divider()

                Button("Verificar Atualizações...") {
                    Task { await updater.checkForUpdates(force: true) }
                }
                .disabled(updater.state.isBusy)
            }
        }
    }

    private func fitHarnessWindowIfNeeded() {
        guard ProcessInfo.processInfo.environment["NH_TEST_FIXTURE_PROVIDER_URL"] != nil,
              let window = NSApp.windows.first,
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(1000, visible.width)
        let height = min(700, visible.height)
        window.setFrame(
            NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
            display: true
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationHandler?()
    }
}
