import SwiftUI
import WebKit

/// Renders an HTML email body in a WKWebView.
///
/// When `blockRemote` is true, a Content-Security-Policy is injected so the page
/// can only load inline (`data:`) images and inline styles — remote images,
/// scripts and tracking pixels are blocked until the user opts in.
struct HTMLView: NSViewRepresentable {
    let html: String
    var blockRemote: Bool = true

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(document(), baseURL: nil)
    }

    private func document() -> String {
        guard blockRemote else { return html }
        let csp = "<meta http-equiv=\"Content-Security-Policy\" "
            + "content=\"default-src 'none'; img-src data: cid:; "
            + "style-src 'unsafe-inline' data:; font-src data:;\">"
        return csp + html
    }
}
