import AppKit
import SwiftUI

@main
struct PocketWikiMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = WikiAppStore()
    @State private var updater = CanonicalUpdater()
    #if NH_RUNTIME_TEST_HOOK
    @State private var runtimeTestReady = false
    #endif

    private var defaultWindowSize: (width: Double, height: Double) {
        ProcessInfo.processInfo.environment["NH_TEST_FIXTURE_PROVIDER_URL"] == nil
            ? (1440, 900)
            : (1000, 700)
    }

    var body: some Scene {
        WindowGroup("PocketWiki", id: "main") {
            Group {
                #if NH_RUNTIME_TEST_HOOK
                if ProcessInfo.processInfo.environment["NH_RUNTIME_LEGACY_UI"] == "1" {
                    VStack { if runtimeTestReady { NHRuntimeLegacySlot() }; ContentView(store: store, updater: updater) }
                } else { ContentView(store: store, updater: updater) }
                #else
                ContentView(store: store, updater: updater)
                #endif
            }
                .frame(minWidth: 980, minHeight: 680)
                .task {
                    fitHarnessWindowIfNeeded()
                    appDelegate.terminationHandler = { [weak store] in
                        store?.shutdownManagedServices()
                    }
                    await store.restoreLastSource()
                    if ProcessInfo.processInfo.environment["NH_TEST_INITIAL_TAB"] == "localAI" {
                        store.selectedTab = .localAI
                    }
                    await store.bootstrapManagedServices()
                    #if NH_RUNTIME_TEST_HOOK
                    runtimeTestReady = true
                    #endif
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

#if NH_RUNTIME_TEST_HOOK
private struct NHRuntimeLegacySlot: View {
    @StateObject private var session: RuntimeUISession
    init() {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["NH_TEST_KERNEL_URL"], let url = URL(string: base),
              let schemaPath = env["NH_RUNTIME_SCHEMA_PATH"],
              let schema = try? Data(contentsOf: URL(fileURLWithPath: schemaPath)),
              let transport = try? RuntimeTransport(baseURL: url, bearer: "fixture"),
              let session = try? RuntimeUISession(transport: transport,
                  environmentID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                  threadID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                  schemaHash: String(repeating: "0", count: 64), schemaData: schema) else {
            fatalError("Invalid test runtime configuration")
        }
        _session = StateObject(wrappedValue: session)
    }
    var body: some View { RuntimePanel(session: session).frame(height: 180) }
}
#endif
