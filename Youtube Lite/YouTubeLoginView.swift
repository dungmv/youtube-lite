import SwiftUI
import WebKit

struct YouTubeLoginView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var authManager = YouTubeAuthManager.shared
    
    var body: some View {
        VStack {
            HStack {
                Text("Login to YouTube")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
            .padding()
            
            WebView(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/signin?next=%2F&hl=en")!) { cookieString in
                if !cookieString.isEmpty {
                    authManager.saveCookies(cookieString)
                    dismiss()
                }
            }
        }
        .frame(minWidth: 500, minHeight: 600)
    }
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct WebView: PlatformViewRepresentable {
    let url: URL
    let onCookiesExtracted: (String) -> Void
    
    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        return makeWebView(context: context)
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        updateWebView(nsView, context: context)
    }
    #else
    func makeUIView(context: Context) -> WKWebView {
        return makeWebView(context: context)
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        updateWebView(uiView, context: context)
    }
    #endif
    
    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    private func updateWebView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        
        init(_ parent: WebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, url.host?.contains("youtube.com") == true {
                Task {
                    let cookieString = await YouTubeAuthManager.shared.extractCookies(from: webView.configuration.websiteDataStore)
                    if cookieString.contains("SID=") {
                        await MainActor.run {
                            parent.onCookiesExtracted(cookieString)
                        }
                    }
                }
            }
        }
    }
}
