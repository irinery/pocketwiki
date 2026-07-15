import SwiftUI
import WebKit
import OSLog

private let graphLogger = Logger(subsystem: "com.irinery.PocketWikiMac", category: "Graph")

struct WikiGraphPanel: View {
    let graph: WikiGraphSnapshot
    let filteredGraph: FilteredSnapshot
    let filterConfig: FilterConfig
    let selectedPageID: String?
    @Binding var scope: WikiGraphScope
    @Binding var depth: Double
    @Binding var search: String
    let onSelectPage: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    titleBlock
                    Spacer(minLength: 12)
                    scopePicker
                    depthControl
                    searchField
                }

                VStack(alignment: .leading, spacing: 10) {
                    titleBlock
                    HStack(spacing: 12) {
                        scopePicker
                        depthControl
                        searchField
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    titleBlock
                    scopePicker
                    depthControl
                    searchField
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let selectedNode {
                selectionStrip(selectedNode)

                Rectangle()
                    .fill(PocketWikiTheme.border)
                    .frame(height: 1)
            }

            Rectangle()
                .fill(PocketWikiTheme.border)
                .frame(height: 1)

            WikiGraphWebView(graph: graph, filterConfig: filterConfig, selectedPageID: selectedPageID, onSelectPage: onSelectPage)
                .frame(minHeight: 560)
                .background(PocketWikiTheme.bg.opacity(0.72))
        }
        .pocketWikiCard()
    }

    private var summaryText: String {
        filteredGraph.nodes.isEmpty ? "sem arquivos conectados" : "\(filteredGraph.nodes.count) arquivos / \(filteredGraph.edges.count) links"
    }

    private var selectedNode: GraphNode? {
        guard let selectedPageID else { return nil }
        return graph.nodeByID[selectedPageID]
    }

    private var titleBlock: some View {
        HStack(spacing: 10) {
            Label("Grafo", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
                .foregroundStyle(PocketWikiTheme.text)

            Text(summaryText)
                .font(.caption)
                .foregroundStyle(PocketWikiTheme.dim)
                .lineLimit(1)
        }
    }

    private var scopePicker: some View {
        Picker("Escopo", selection: $scope) {
            ForEach(WikiGraphScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 150)
        .help("Alterna entre conexoes da pagina atual e mapa global")
    }

    private var depthControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .foregroundStyle(PocketWikiTheme.muted)
            Slider(value: $depth, in: 1...10, step: 1)
                .frame(width: 116)
                .disabled(scope != .local)
                .opacity(scope == .local ? 1 : 0.42)
            Text("\(Int(depth))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(PocketWikiTheme.dim)
                .frame(width: 20, alignment: .trailing)
        }
        .help("Profundidade de vizinhanca no modo Local")
    }

    private var searchField: some View {
        TextField("Buscar no grafo", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .help("Destaca nos por titulo sem mudar o escopo")
    }

    private func selectionStrip(_ node: GraphNode) -> some View {
        HStack(spacing: 12) {
            Label(node.label, systemImage: node.status == .orphanTarget ? "questionmark.circle" : "doc.text")
                .font(.callout.weight(.semibold))
                .foregroundStyle(PocketWikiTheme.text)
                .lineLimit(1)

            Text("\(node.degreeIn) backlinks")
                .font(.caption)
                .foregroundStyle(PocketWikiTheme.dim)

            Text("\(node.degreeOut) outlinks")
                .font(.caption)
                .foregroundStyle(PocketWikiTheme.dim)

            if node.truncated {
                Label("links truncados", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(PocketWikiTheme.warn)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(PocketWikiTheme.bg2.opacity(0.42))
    }
}

private struct WikiGraphWebView: NSViewRepresentable {
    let graph: WikiGraphSnapshot
    let filterConfig: FilterConfig
    let selectedPageID: String?
    let onSelectPage: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "pocketwikiGraph")
        userContentController.addUserScript(Self.diagnosticsScript)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.loadGraph(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(webView)
    }

    private static var graphBundleRoot: URL? {
        PocketWikiResourceBundle.resourceURL
    }

    private static let diagnosticsScript = WKUserScript(
        source: """
        (() => {
          const post = (type, payload) => {
            try {
              window.webkit?.messageHandlers?.pocketwikiGraph?.postMessage({ type, ...payload });
            } catch (_) {}
          };
          window.addEventListener("error", (event) => {
            post("error", { message: `${event.message || "erro JS"} ${event.filename || ""}:${event.lineno || 0}:${event.colno || 0}` });
          });
          window.addEventListener("unhandledrejection", (event) => {
            post("error", { message: `Promise rejeitada: ${String(event.reason || "")}` });
          });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WikiGraphWebView
        private weak var webView: WKWebView?
        private var isReady = false
        private var lastSignature = ""

        init(_ parent: WikiGraphWebView) {
            self.parent = parent
        }

        func loadGraph(in webView: WKWebView) {
            self.webView = webView
            guard let root = WikiGraphWebView.graphBundleRoot else { return }
            let index = root.appendingPathComponent("index.html", isDirectory: false)
            webView.loadFileURL(index, allowingReadAccessTo: root)
        }

        func sync(_ webView: WKWebView) {
            guard isReady else { return }
            let signature = [
                parent.graph.signature,
                parent.filterConfig.scope.rawValue,
                "\(parent.filterConfig.depth)",
                parent.filterConfig.selectedNodeID ?? "",
                parent.filterConfig.searchTerm
            ].joined(separator: "::")
            guard signature != lastSignature else { return }
            lastSignature = signature
            send(payload(), to: webView)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "pocketwikiGraph",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "ready":
                isReady = true
                if let webView {
                    sync(webView)
                }
            case "selectPage":
                if let id = body["id"] as? String {
                    parent.onSelectPage(id)
                }
            case "error", "diagnostic":
                let text = body["message"] as? String ?? body["status"] as? String ?? "diagnostico do grafo"
                graphLogger.error("\(text, privacy: .public)")
            case "layoutStatus":
                let status = body["status"] as? String ?? "unknown"
                graphLogger.debug("layout status: \(status, privacy: .public)")
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if isReady {
                sync(webView)
            }
        }

        private func payload() -> GraphWebPayload {
            GraphWebPayload(graph: parent.graph, filter: parent.filterConfig)
        }

        private func send(_ object: GraphWebPayload, to webView: WKWebView) {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(object),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }

            webView.evaluateJavaScript("window.PocketWikiGraph?.receive(\(json));") { _, error in
                guard let error else { return }
                graphLogger.error("graph send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct GraphWebPayload: Encodable {
    let command = "setGraph"
    let graph: GraphSnapshot
    let filter: FilterConfig
}
