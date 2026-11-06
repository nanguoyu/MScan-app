import MScanCore
import SwiftUI
import WebKit

struct GeoMapLink {
    let point: GeoCoordinate
    private func formatted(_ value: Double) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    var permalink: URL {
        var parts = URLComponents(string: "https://www.openstreetmap.org/")!
        parts.queryItems = [.init(name: "mlat", value: formatted(point.latitude)), .init(name: "mlon", value: formatted(point.longitude))]
        parts.fragment = "map=8/" + formatted(point.latitude) + "/" + formatted(point.longitude)
        return parts.url!
    }

    var embed: URL? {
        // The OSM raster layer ends at the Web Mercator latitude limit.
        let limit = 85.0511
        guard abs(point.latitude) <= limit else { return nil }
        let bounds = [max(-180, point.longitude - 0.8), max(-limit, point.latitude - 0.55),
                      min(180, point.longitude + 0.8), min(limit, point.latitude + 0.55)]
        var parts = URLComponents(string: "https://www.openstreetmap.org/export/embed.html")!
        parts.queryItems = [.init(name: "bbox", value: bounds.map(formatted).joined(separator: ",")),
                            .init(name: "layer", value: "mapnik"),
                            .init(name: "marker", value: [point.latitude, point.longitude].map(formatted).joined(separator: ","))]
        return parts.url
    }
}

struct GeoMapPanel: View {
    let point: GeoCoordinate
    let source: String
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false
    @State private var loading = true
    @State private var attempt = 0
    private var link: GeoMapLink { GeoMapLink(point: point) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: geoText("map.title"), icon: "map", subtitle: source)
            Divider()
            Group {
                if let embed = link.embed, !failed {
                    GeoEmbeddedMap(url: embed, failed: $failed, loading: $loading).id(attempt)
                        .overlay { if loading { ProgressView(geoText("map.loading")).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) } }
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "map").font(.title2)
                        Text(geoText("map.unavailable")).font(.callout)
                        if link.embed != nil { Button(geoText("retry")) { attempt += 1; loading = true; failed = false } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: 310)
            Divider()
            HStack {
                Link(geoText("map.attribution"), destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Spacer()
                Link(geoText("map.browser"), destination: link.permalink)
                Button(geoText("done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.font(.callout).padding(14)
        }.frame(width: 560)
    }
}

private struct GeoEmbeddedMap: NSViewRepresentable {
    let url: URL
    @Binding var failed: Bool
    @Binding var loading: Bool
    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed, loading: $loading) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = "MScan/1.0"
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {}
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { web.navigationDelegate = nil; web.stopLoading() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let failed: Binding<Bool>
        let loading: Binding<Bool>
        init(failed: Binding<Bool>, loading: Binding<Bool>) { self.failed = failed; self.loading = loading }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading.wrappedValue = false }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            let allowed = url?.scheme == "https" && url?.host == "www.openstreetmap.org" && url?.path == "/export/embed.html"
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                failed.wrappedValue = true
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { failed.wrappedValue = true }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { failed.wrappedValue = true }
        }
    }
}
