import AppKit
import SwiftUI

@main
struct PocketWikiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WikiAppStore()

    var body: some Scene {
        WindowGroup("PocketWiki", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 680)
                .task {
                    await store.restoreLastSource()
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
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
