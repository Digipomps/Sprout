import SwiftUI
import WebKit

struct PortholeWebView: NSViewRepresentable {
    let request: URLRequest

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(request)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != request.url {
            nsView.load(request)
        }
    }
}
