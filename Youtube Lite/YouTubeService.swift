import Foundation
import JavaScriptCore

// MARK: - InnerTube Response Models

struct YouTubePlayerResponse: Codable {
    let streamingData: StreamingData?
    let videoDetails: VideoDetails?
    let playabilityStatus: PlayabilityStatus?
}

struct StreamingData: Codable {
    let formats: [VideoFormat]?
    let adaptiveFormats: [VideoFormat]?
    let expiresInSeconds: String?
}

struct VideoFormat: Codable {
    let itag: Int
    let url: String?
    let signatureCipher: String?
    let mimeType: String?
    let bitrate: Int32?
    let width: Int?
    let height: Int?
    let contentLength: String?
    let quality: String?
    let qualityLabel: String?
    let fps: Int?
    let audioQuality: String?
    let audioSampleRate: String?
    let audioChannels: Int?
    let approxDurationMs: String?
    let projectionType: String?
    let averageBitrate: Int32?
    let highReplication: Bool?
}

struct VideoDetails: Codable {
    let videoId: String?
    let title: String?
    let lengthSeconds: String?
    let author: String?
    let channelId: String?
    let isOwnerViewing: Bool?
    let shortDescription: String?
    let isCrawlable: Bool?
    let thumbnail: Thumbnail?
    let allowRatings: Bool?
    let viewCount: String?
    let isPrivate: Bool?
    let isUnpluggedCorpus: Bool?
    let isLiveContent: Bool?
}

struct Thumbnail: Codable {
    let thumbnails: [ThumbnailItem]?
}

struct ThumbnailItem: Codable {
    let url: String?
    let width: Int?
    let height: Int?
}

struct PlayabilityStatus: Codable {
    let status: String?
    let reason: String?
    let errorScreen: ErrorScreen?
}

struct ErrorScreen: Codable {
    let playerErrorMessageRenderer: PlayerErrorMessageRenderer?
}

struct PlayerErrorMessageRenderer: Codable {
    let reason: TextRun?
    let subreason: TextRun?
}

struct TextRun: Codable {
    let runs: [RunItem]?
}

struct RunItem: Codable {
    let text: String?
}

// MARK: - Request Models

struct InnerTubeContext: Codable {
    let client: YouTubeClient
    let user: YouTubeUser?
    let request: YouTubeRequest?
}

struct YouTubeClient: Codable {
    let hl: String
    let gl: String
    let clientName: String
    let clientVersion: String
    let platform: String
    let clientFormFactor: String
}

struct YouTubeUser: Codable {
    let lockedSafetyMode: Bool
}

struct YouTubeRequest: Codable {
    let useSsl: Bool
    let contentCheckOk: Bool?
    let racyCheckOk: Bool?
}

struct PlaybackContext: Codable {
    let contentPlaybackContext: ContentPlaybackContext?
}

struct ContentPlaybackContext: Codable {
    let html5Preference: String
    let signatureTimestamp: Int
}

struct PlayerRequestBody: Codable {
    let videoId: String
    let context: InnerTubeContext
    let playbackContext: PlaybackContext?
}

// MARK: - Stream Info for UI

struct VideoStreamInfo: Identifiable {
    let id = UUID()
    let itag: Int
    let quality: String
    let mimeType: String?
    let directURL: URL?
    let contentLength: Int64?
    let isAdaptive: Bool
}

// MARK: - Page config extracted from YouTube homepage
struct YouTubePageConfig {
    let apiKey: String?
    let clientVersion: String?
    let jsUrl: String?
    var signatureTimestamp: Int? = nil
}

class YouTubeService {
    static let shared = YouTubeService()
    
    // Hardcoded defaults (used when network unavailable or first launch)
    private let defaultAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private let defaultClientVersion = "2.20260508.01.00"
    private let defaultSignatureTimestamp = 20577
    private let defaultPlayerJSUrl = "https://www.youtube.com/s/player/8fb635c2/player_ias.vflset/vi_VN/base.js"
    
    private var apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    private var clientVersion = "2.20260508.01.00"
    private var playerJSUrl: String?
    private var jsContext: JSContext?
    private var decipherFuncName: String?
    private var nTransFuncName: String?
    private var signatureTimestamp: Int?
    private var isPlayerJSLoaded = false
    private var baseJSContent: String?
    private let session = URLSession.shared
    
    private enum CacheKeys {
        static let apiKey = "YT_API_KEY"
        static let clientVersion = "YT_CLIENT_VERSION"
        static let signatureTimestamp = "YT_SIG_TIMESTAMP"
        static let playerJSUrl = "YT_PLAYER_JS_URL"
    }
    
    private var playerJSCacheURL: URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("yt_player_base.js")
    }
    
    // MARK: - Configuration
    
    func loadConfig(completion: @escaping (Error?) -> Void) {
        // 1. Try cached config from previous successful fetch
        if let cached = loadCachedConfig() {
            self.apiKey = cached.apiKey ?? self.defaultAPIKey
            self.clientVersion = cached.clientVersion ?? self.defaultClientVersion
            self.signatureTimestamp = cached.signatureTimestamp ?? self.defaultSignatureTimestamp
            self.playerJSUrl = cached.jsUrl ?? self.defaultPlayerJSUrl
            self.loadPlayerJS(jsUrl: self.playerJSUrl!, completion: completion)
            // Refresh in background
            DispatchQueue.global().async { [weak self] in
                self?.fetchYouTubePage { [weak self] result in
                    if case .success(let config) = result {
                        self?.saveConfigToCache(config)
                    }
                }
            }
            return
        }
        
        // 2. No cache, attempt network fetch
        fetchYouTubePage { [weak self] result in
            switch result {
            case .success(let config):
                self?.saveConfigToCache(config)
                self?.apiKey = config.apiKey ?? self?.defaultAPIKey ?? ""
                self?.clientVersion = config.clientVersion ?? self?.defaultClientVersion ?? ""
                let jsUrl = config.jsUrl ?? self?.defaultPlayerJSUrl ?? ""
                self?.playerJSUrl = jsUrl
                self?.loadPlayerJS(jsUrl: jsUrl, completion: completion)
            case .failure(let error):
                print("⚠️ Network config fetch failed: \(error.localizedDescription) – using hardcoded defaults")
                self?.apiKey = self?.defaultAPIKey ?? ""
                self?.clientVersion = self?.defaultClientVersion ?? ""
                self?.signatureTimestamp = self?.defaultSignatureTimestamp
                let fallbackJs = self?.defaultPlayerJSUrl ?? ""
                self?.playerJSUrl = fallbackJs
                self?.loadPlayerJS(jsUrl: fallbackJs) { loadError in
                    if let loadError = loadError {
                        print("⚠️ Player JS load also failed: \(loadError.localizedDescription) – video deciphering unavailable")
                    }
                    // Complete without error; video streams may just lack direct URLs
                    completion(nil)
                }
            }
        }
    }
    
    private func fetchYouTubePage(completion: @escaping (Result<YouTubePageConfig, Error>) -> Void) {
        guard let url = URL(string: "https://www.youtube.com") else {
            completion(.failure(NSError(domain: "YouTubeService", code: 2, userInfo: nil)))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(NSError(domain: "YouTubeService", code: 3, userInfo: nil)))
                return
            }
            
            let extractString = { (pattern: String) -> String? in
                guard let range = html.range(of: pattern, options: .regularExpression) else { return nil }
                let matched = String(html[range])
                return matched.components(separatedBy: "\"").first { $0.contains(".") || $0.contains("/s/player") || $0.contains("AIza") }
            }
            
            let apiKey = extractString(#""innertubeApiKey"\s*:\s*"([^"]+)""#)
            let clientVersion = extractString(#""clientVersion"\s*:\s*"([^"]+)""#)
            var jsUrl: String? = extractString(#""jsUrl"\s*:\s*"([^"]+)""#)
            if let path = jsUrl { jsUrl = "https://www.youtube.com" + path }
            else {
                jsUrl = extractString(#"src="(/s/player/[^"]+/base\.js)""#)
                if let path = jsUrl { jsUrl = "https://www.youtube.com" + path }
            }
            
            completion(.success(YouTubePageConfig(apiKey: apiKey, clientVersion: clientVersion, jsUrl: jsUrl)))
        }.resume()
    }
    
    private func loadCachedConfig() -> YouTubePageConfig? {
        let defaults = UserDefaults.standard
        guard let apiKey = defaults.string(forKey: CacheKeys.apiKey) else { return nil }
        return YouTubePageConfig(
            apiKey: apiKey,
            clientVersion: defaults.string(forKey: CacheKeys.clientVersion),
            jsUrl: defaults.string(forKey: CacheKeys.playerJSUrl),
            signatureTimestamp: defaults.object(forKey: CacheKeys.signatureTimestamp) as? Int
        )
    }
    
    private func saveConfigToCache(_ config: YouTubePageConfig) {
        let defaults = UserDefaults.standard
        if let key = config.apiKey { defaults.set(key, forKey: CacheKeys.apiKey) }
        if let version = config.clientVersion { defaults.set(version, forKey: CacheKeys.clientVersion) }
        if let ts = config.signatureTimestamp { defaults.set(ts, forKey: CacheKeys.signatureTimestamp) }
        if let js = config.jsUrl { defaults.set(js, forKey: CacheKeys.playerJSUrl) }
    }
    
    private func loadPlayerJS(jsUrl: String, completion: @escaping (Error?) -> Void) {
        // Try loading from cache file first
        if let cachedJS = try? String(contentsOf: playerJSCacheURL, encoding: .utf8), !cachedJS.isEmpty {
            self.baseJSContent = cachedJS
            self.extractPlayerConfig(from: cachedJS)
            self.initializeJSContext(with: cachedJS)
            // Refresh in background
            DispatchQueue.global().async { [weak self] in
                self?.fetchAndCachePlayerJS(jsUrl: jsUrl) { [weak self] jsString, _ in
                    if let jsString = jsString {
                        self?.baseJSContent = jsString
                        self?.extractPlayerConfig(from: jsString)
                        self?.initializeJSContext(with: jsString)
                    }
                }
            }
            completion(nil)
            return
        }
        
        // Fetch from network
        fetchAndCachePlayerJS(jsUrl: jsUrl) { [weak self] jsString, error in
            if let jsString = jsString {
                self?.baseJSContent = jsString
                self?.extractPlayerConfig(from: jsString)
                self?.initializeJSContext(with: jsString)
                completion(nil)
            } else {
                // Last attempt: cache file (maybe another thread updated it)
                if let cachedJS = try? String(contentsOf: self?.playerJSCacheURL ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8), !cachedJS.isEmpty {
                    self?.baseJSContent = cachedJS
                    self?.extractPlayerConfig(from: cachedJS)
                    self?.initializeJSContext(with: cachedJS)
                    completion(nil)
                } else {
                    completion(error ?? NSError(domain: "YouTubeService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Player JS not available"]))
                }
            }
        }
    }
    
    private func fetchAndCachePlayerJS(jsUrl: String, completion: @escaping (String?, Error?) -> Void) {
        guard let url = URL(string: jsUrl) else {
            completion(nil, NSError(domain: "YouTubeService", code: 4, userInfo: nil))
            return
        }
        session.dataTask(with: url) { [weak self] data, _, error in
            if let error = error {
                completion(nil, error)
                return
            }
            guard let data = data, let jsString = String(data: data, encoding: .utf8) else {
                completion(nil, NSError(domain: "YouTubeService", code: 5, userInfo: nil))
                return
            }
            // Save to cache
            try? jsString.write(to: self?.playerJSCacheURL ?? URL(fileURLWithPath: "/dev/null"), atomically: true, encoding: .utf8)
            completion(jsString, nil)
        }.resume()
    }
    
    private func extractPlayerConfig(from js: String) {
        // signatureTimestamp
        if let range = js.range(of: #"signatureTimestamp:(\d+)"#, options: .regularExpression) {
            let subs = String(js[range])
            let ts = Int(subs.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
            self.signatureTimestamp = ts
            if let ts = ts {
                UserDefaults.standard.set(ts, forKey: CacheKeys.signatureTimestamp)
            }
        }
        
        // signature decipher function name
        if let range = js.range(of: #"\.set\("signature",\s*([A-Za-z0-9_$]+)\( "#, options: .regularExpression) {
            let line = String(js[range])
            let regex = try? NSRegularExpression(pattern: #"\.set\("signature",\s*([A-Za-z0-9_$]+)\( "#)
            if let nsMatch = regex?.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
               nsMatch.numberOfRanges > 1,
               let swiftRange = Range(nsMatch.range(at: 1), in: line) {
                self.decipherFuncName = String(line[swiftRange])
            }
        }
        
        // n transform function name
        if let range = js.range(of: #"\.set\("n",\s*([A-Za-z0-9_$]+)\( "#, options: .regularExpression) {
            let line = String(js[range])
            let regex = try? NSRegularExpression(pattern: #"\.set\("n",\s*([A-Za-z0-9_$]+)\( "#)
            if let nsMatch = regex?.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
               nsMatch.numberOfRanges > 1,
               let swiftRange = Range(nsMatch.range(at: 1), in: line) {
                self.nTransFuncName = String(line[swiftRange])
            }
        }
    }
    
    private func initializeJSContext(with js: String) {
        let context = JSContext()
        context?.exceptionHandler = { _, exception in
            if let exc = exception {
                print("JS Error: \(exc.toString() ?? "")")
            }
        }
        context?.evaluateScript("""
            var window = this;
            var navigator = { userAgent: 'Mozilla/5.0' };
            var document = {
                querySelector: function(){ return null; },
                createElement: function(){ return { style: {} }; },
                addEventListener: function(){},
                removeEventListener: function(){},
                getElementById: function(){ return null; },
                location: { toString: function(){ return 'https://www.youtube.com'; } }
            };
            var setTimeout = function(){};
            var clearTimeout = function(){};
            var console = { log: function(){}, error: function(){}, warn: function(){} };
            var performance = { now: function(){ return Date.now(); } };
        """)
        context?.evaluateScript(js)
        if context?.exception != nil {
            print("JS evaluation error, but decipher functions may still be accessible")
            context?.exception = nil
        }
        self.jsContext = context
        self.isPlayerJSLoaded = true
    }
    
    // MARK: - Public API
    
    func fetchVideoStreams(videoID: String, completion: @escaping (Result<[VideoStreamInfo], Error>) -> Void) {
        if !isPlayerJSLoaded {
            loadConfig { [weak self] error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                self?.fetchPlayerResponse(videoID: videoID, completion: completion)
            }
        } else {
            fetchPlayerResponse(videoID: videoID, completion: completion)
        }
    }
    
    // MARK: - InnerTube Player Request
    
    private func fetchPlayerResponse(videoID: String, completion: @escaping (Result<[VideoStreamInfo], Error>) -> Void) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)") else {
            completion(.failure(NSError(domain: "YouTubeService", code: 6, userInfo: nil)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                         forHTTPHeaderField: "User-Agent")
        
        let context = InnerTubeContext(
            client: YouTubeClient(hl: "en", gl: "US", clientName: "WEB",
                                  clientVersion: clientVersion, platform: "DESKTOP",
                                  clientFormFactor: "UNKNOWN_FORM_FACTOR"),
            user: YouTubeUser(lockedSafetyMode: false),
            request: YouTubeRequest(useSsl: true, contentCheckOk: true, racyCheckOk: true)
        )
        let playbackCtx: PlaybackContext?
        if let ts = signatureTimestamp {
            playbackCtx = PlaybackContext(contentPlaybackContext:
                ContentPlaybackContext(html5Preference: "HTML5_PREF_WANTS", signatureTimestamp: ts))
        } else {
            playbackCtx = nil
        }
        
        let body = PlayerRequestBody(videoId: videoID, context: context, playbackContext: playbackCtx)
        
        guard let httpBody = try? JSONEncoder().encode(body) else {
            completion(.failure(NSError(domain: "YouTubeService", code: 7, userInfo: nil)))
            return
        }
        request.httpBody = httpBody
        
        session.dataTask(with: request) { [weak self] data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "YouTubeService", code: 8, userInfo: nil)))
                return
            }
            
            do {
                let player = try JSONDecoder().decode(YouTubePlayerResponse.self, from: data)
                guard let streaming = player.streamingData else {
                    let reason = player.playabilityStatus?.reason ?? "No streaming data"
                    completion(.failure(NSError(domain: "YouTubeService", code: 9,
                                                userInfo: [NSLocalizedDescriptionKey: reason])))
                    return
                }
                
                var allFormats = (streaming.formats ?? [])
                allFormats += (streaming.adaptiveFormats ?? [])
                
                let adaptiveSet = Set(streaming.adaptiveFormats?.map(\.itag) ?? [])
                var infos: [VideoStreamInfo] = []
                
                for fmt in allFormats {
                    var directURL: URL?
                    if let urlStr = fmt.url {
                        directURL = self?.processURL(urlStr)
                    } else if let cipher = fmt.signatureCipher {
                        directURL = self?.decipherCipher(cipher)
                    }
                    let quality = fmt.qualityLabel ?? fmt.quality ?? "Unknown"
                    infos.append(VideoStreamInfo(
                        itag: fmt.itag, quality: quality, mimeType: fmt.mimeType,
                        directURL: directURL, contentLength: Int64(fmt.contentLength ?? ""),
                        isAdaptive: adaptiveSet.contains(fmt.itag)
                    ))
                }
                completion(.success(infos))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - URL manipulators
    
    private func processURL(_ urlStr: String) -> URL? {
        guard var comps = URLComponents(string: urlStr) else { return URL(string: urlStr) }
        if var items = comps.queryItems, let nIdx = items.firstIndex(where: { $0.name == "n" }),
           let nVal = items[nIdx].value, let newN = transformNParam(nVal) {
            items[nIdx] = URLQueryItem(name: "n", value: newN)
            comps.queryItems = items
        }
        return comps.url
    }
    
    private func decipherCipher(_ cipher: String) -> URL? {
        guard let decoded = cipher.removingPercentEncoding else { return nil }
        var urlStr: String?, sig: String?, sp: String?
        for pair in decoded.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                switch kv[0] {
                case "url": urlStr = kv[1]
                case "s": sig = kv[1]
                case "sp": sp = kv[1]
                default: break
                }
            }
        }
        guard let urlStr = urlStr, let sig = sig, let deciphered = decipherSignature(sig) else { return nil }
        let param = sp ?? "sig"
        let final = urlStr.contains("?") ? "\(urlStr)&\(param)=\(deciphered)" : "\(urlStr)?\(param)=\(deciphered)"
        return processURL(final)
    }
    
    private func decipherSignature(_ sig: String) -> String? {
        guard let ctx = jsContext, let name = decipherFuncName else { return sig }
        let escaped = sig.replacingOccurrences(of: "\"", with: "\\\"")
        return ctx.evaluateScript("\(name)(\"\(escaped)\")")?.toString()
    }
    
    private func transformNParam(_ n: String) -> String? {
        guard let ctx = jsContext, let name = nTransFuncName else { return n }
        let escaped = n.replacingOccurrences(of: "\"", with: "\\\"")
        return ctx.evaluateScript("\(name)(\"\(escaped)\")")?.toString()
    }
}
