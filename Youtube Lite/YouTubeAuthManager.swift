import Foundation
import Combine
import WebKit

@MainActor
public class YouTubeAuthManager: ObservableObject {
    public static let shared = YouTubeAuthManager()
    
    @Published public var isLoggedIn: Bool = false
    @Published public var cookies: String = ""
    
    private let cookieName = "youtube_cookies"
    
    init() {
        loadCookies()
    }
    
    public func loadCookies() {
        if let storedCookies = UserDefaults.standard.string(forKey: cookieName) {
            self.cookies = storedCookies
            self.isLoggedIn = !storedCookies.isEmpty
        }
    }
    
    public func saveCookies(_ cookieString: String) {
        self.cookies = cookieString
        UserDefaults.standard.set(cookieString, forKey: cookieName)
        self.isLoggedIn = !cookieString.isEmpty
    }
    
    public func logout() {
        self.cookies = ""
        self.isLoggedIn = false
        UserDefaults.standard.removeObject(forKey: cookieName)
        
        // Clear WKWebView cookies
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                // Done
            }
        }
    }
    
    public func extractCookies(from websiteDataStore: WKWebsiteDataStore) async -> String {
        let cookies = await websiteDataStore.httpCookieStore.allCookies()
        // We need SID, HSID, SSID, APISID, SAPISID, __Secure-3PSID, etc.
        // For simplicity, we join all cookies that belong to .youtube.com or .google.com
        let cookieStrings = cookies
            .filter { $0.domain.contains("youtube.com") || $0.domain.contains("google.com") }
            .map { "\($0.name)=\($0.value)" }
        
        return cookieStrings.joined(separator: "; ")
    }
}
