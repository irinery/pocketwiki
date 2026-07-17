import AppKit
import SwiftUI

@main
struct PocketWikiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WikiAppStore()
    @State private var updater = CanonicalUpdater()

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
        .defaultSize(width: 1440, height: 900)
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
