import SwiftUI
import WebKit

struct ExcalidrawEditorDocument: Equatable {
    let id: String
    let title: String
    let path: String
    let content: String
    let readonly: Bool
}

struct ExcalidrawSavePayload: Equatable {
    let id: String
    let path: String
    let title: String
    let content: String
    let saveMode: String
    let reason: String
}

enum ExcalidrawEditorEvent: Equatable {
    case ready
    case diagnostic(String)
    case dirtyChanged(id: String, path: String, dirty: Bool)
    case saveRequested(ExcalidrawSavePayload)
    case autosaveRequested(ExcalidrawSavePayload)
    case error(id: String, path: String, message: String)
}

struct ExcalidrawWebView: NSViewRepresentable {
    let document: ExcalidrawEditorDocument?
    let saveRequestID: Int
    let exportRequestID: Int
    let createBlankRequestID: Int
    let onEvent: (ExcalidrawEditorEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "pocketwikiExcalidraw")
        userContentController.addUserScript(Self.diagnosticsScript)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if let root = Self.editorBundleRoot {
            configuration.setURLSchemeHandler(
                ExcalidrawEditorSchemeHandler(root: root),
                forURLScheme: ExcalidrawEditorResourceResolver.scheme
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.loadEditor(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(webView)
    }

    private static var editorBundleRoot: URL? {
        PocketWikiResourceBundle.resourceURL?.appendingPathComponent("ExcalidrawEditor", isDirectory: true)
    }

    private static let diagnosticsScript = WKUserScript(
        source: """
        (() => {
          const stringify = (value) => {
            try {
              if (value instanceof Error) return `${value.name}: ${value.message}`;
              if (typeof value === "string") return value;
              return JSON.stringify(value);
            } catch (_) {
              return String(value);
            }
          };
          const post = (type, payload) => {
            try {
              window.webkit?.messageHandlers?.pocketwikiExcalidraw?.postMessage({ type, ...payload });
            } catch (_) {}
          };
          window.addEventListener("error", (event) => {
            post("error", {
              message: `JS error: ${event.message || "erro desconhecido"} ${event.filename || ""}:${event.lineno || 0}:${event.colno || 0}`
            });
          });
          window.addEventListener("unhandledrejection", (event) => {
            post("error", { message: `Promise rejeitada: ${stringify(event.reason)}` });
          });
          const wrapConsole = (level) => {
            const original = console[level]?.bind(console);
            if (!original) return;
            console[level] = (...args) => {
              post("diagnostic", { message: `${level}: ${args.map(stringify).join(" ")}` });
              original(...args);
            };
          };
          wrapConsole("error");
          wrapConsole("warn");
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ExcalidrawWebView
        private var isReady = false
        private weak var webView: WKWebView?
        private var readyTimeout: DispatchWorkItem?
        private var sentDocument: ExcalidrawEditorDocument?
        private var lastSaveRequestID = 0
        private var lastExportRequestID = 0
        private var lastCreateBlankRequestID = 0

        init(_ parent: ExcalidrawWebView) {
            self.parent = parent
        }

        func loadEditor(in webView: WKWebView) {
            self.webView = webView
            guard ExcalidrawWebView.editorBundleRoot != nil,
                  let index = URL(string: "\(ExcalidrawEditorResourceResolver.scheme)://\(ExcalidrawEditorResourceResolver.host)/index.html") else {
                parent.onEvent(.error(id: "", path: "", message: "Bundle ExcalidrawEditor nao encontrado. Rode npm run build:excalidraw."))
                return
            }

            scheduleReadyTimeout()
            webView.load(URLRequest(url: index))
        }

        func sync(_ webView: WKWebView) {
            guard isReady else { return }

            if parent.createBlankRequestID != lastCreateBlankRequestID {
                lastCreateBlankRequestID = parent.createBlankRequestID
                send(["command": "createBlank"], to: webView)
                sentDocument = nil
            }

            if let document = parent.document, document != sentDocument {
                sentDocument = document
                send([
                    "command": "loadDocument",
                    "id": document.id,
                    "title": document.title,
                    "path": document.path,
                    "content": document.content,
                    "readonly": document.readonly
                ], to: webView)
            } else if parent.document == nil, sentDocument != nil {
                sentDocument = nil
            }

            if parent.saveRequestID != lastSaveRequestID {
                lastSaveRequestID = parent.saveRequestID
                send(["command": "requestSave", "mode": "document"], to: webView)
            }

            if parent.exportRequestID != lastExportRequestID {
                lastExportRequestID = parent.exportRequestID
                send(["command": "requestSave", "mode": "export"], to: webView)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "pocketwikiExcalidraw",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "ready":
                isReady = true
                readyTimeout?.cancel()
                parent.onEvent(.ready)
                if let webView {
                    sync(webView)
                }
            case "diagnostic":
                parent.onEvent(.diagnostic(body["message"] as? String ?? "diagnostico Excalidraw vazio"))
            case "dirtyChanged":
                parent.onEvent(.dirtyChanged(
                    id: body["id"] as? String ?? "",
                    path: body["path"] as? String ?? "",
                    dirty: body["dirty"] as? Bool ?? false
                ))
            case "saveRequested":
                parent.onEvent(.saveRequested(Self.savePayload(from: body)))
            case "autosaveRequested":
                parent.onEvent(.autosaveRequested(Self.savePayload(from: body)))
            case "error":
                parent.onEvent(.error(
                    id: body["id"] as? String ?? "",
                    path: body["path"] as? String ?? "",
                    message: body["message"] as? String ?? "Erro no editor Excalidraw."
                ))
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onEvent(.diagnostic("Editor Excalidraw carregou o HTML."))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onEvent(.error(id: "", path: sentDocument?.path ?? "", message: "Falha ao carregar editor Excalidraw: \(error.localizedDescription)"))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onEvent(.error(id: "", path: sentDocument?.path ?? "", message: "Falha inicial ao carregar editor Excalidraw: \(error.localizedDescription)"))
        }

        private func send(_ object: [String: Any], to webView: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript("window.PocketExcalidrawDesktop?.receive(\(json));") { [weak self] _, error in
                guard let self, let error else { return }
                self.parent.onEvent(.error(
                    id: "",
                    path: self.sentDocument?.path ?? "",
                    message: "Falha ao enviar comando para Excalidraw: \(error.localizedDescription)"
                ))
            }
        }

        private func scheduleReadyTimeout() {
            readyTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, !self.isReady else { return }
                self.parent.onEvent(.error(
                    id: "",
                    path: self.sentDocument?.path ?? "",
                    message: "Editor Excalidraw nao terminou de iniciar. Verifique os diagnosticos do WKWebView."
                ))
            }
            readyTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }

        private static func savePayload(from body: [String: Any]) -> ExcalidrawSavePayload {
            ExcalidrawSavePayload(
                id: body["id"] as? String ?? "",
                path: body["path"] as? String ?? "",
                title: body["title"] as? String ?? "Desenho",
                content: body["content"] as? String ?? "",
                saveMode: body["saveMode"] as? String ?? "document",
                reason: body["reason"] as? String ?? "manual"
            )
        }
    }
}
