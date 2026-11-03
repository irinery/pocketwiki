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
