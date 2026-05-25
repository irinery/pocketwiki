import Foundation
import WebKit

final class ExcalidrawEditorSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resolver: ExcalidrawEditorResourceResolver

    init(root: URL) {
        self.resolver = ExcalidrawEditorResourceResolver(root: root)
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            let resource = try resolver.resolve(urlSchemeTask.request.url ?? URL(fileURLWithPath: ""))
            let response = URLResponse(
                url: urlSchemeTask.request.url ?? resource.url,
                mimeType: resource.mimeType,
                expectedContentLength: resource.data.count,
                textEncodingName: resource.mimeType.hasPrefix("text/") ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(resource.data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // WKWebView owns cancellation. The resources are loaded synchronously from the app bundle.
    }
}
