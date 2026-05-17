import SwiftUI
import WebKit

// MARK: - YouTube Login Router
struct YouTubeLoginView: View {
    var body: some View {
        #if os(macOS)
        MacYouTubeLoginView()
        #else
        iOSYouTubeLoginView()
        #endif
    }
}

// MARK: - macOS Platform Login View
#if os(macOS)
struct MacYouTubeLoginView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var authManager = YouTubeAuthManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Login to YouTube")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            MacWebView(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/signin?next=%2F&hl=en")!) { cookieString in
                if !cookieString.isEmpty {
                    authManager.saveCookies(cookieString)
                    dismiss()
                }
            }
        }
        .frame(minWidth: 550, minHeight: 650)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct MacWebView: NSViewRepresentable {
    let url: URL
    let onCookiesExtracted: (String) -> Void
    
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        nsView.load(request)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MacWebView
        
        init(_ parent: MacWebView) {
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
#endif

// MARK: - iOS Platform Login View
#if os(iOS)
struct iOSYouTubeLoginView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var authManager = YouTubeAuthManager.shared
    
    var body: some View {
        NavigationView {
            iOSWebView(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/signin?next=%2F&hl=en")!) { cookieString in
                if !cookieString.isEmpty {
                    authManager.saveCookies(cookieString)
                    dismiss()
                }
            }
            .navigationTitle("Login to YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct iOSWebView: UIViewRepresentable {
    let url: URL
    let onCookiesExtracted: (String) -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        uiView.load(request)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: iOSWebView
        
        init(_ parent: iOSWebView) {
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
#endif
