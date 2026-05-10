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
    let cipher: String?
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
            print("[Config] signatureTimestamp: \(ts ?? -1)")
        } else {
            print("[Config] signatureTimestamp: NOT FOUND")
        }
        
        // signature decipher function name
        let decipherPatterns: [(String, String)] = [
            (#"\.set\(["']signature["'],\s*([A-Za-z0-9_$]+)(?:\.call|\.apply)?\("#, "direct-call"),
            (#"(?:var|let|const)\s+([A-Za-z0-9_$]+)\s*=\s*function\s*\(\s*a\s*\)\s*\{\s*a\s*=\s*a\s*\.split\s*\(\s*""\s*\)"#, "split-body"),
        ]
        for (pattern, desc) in decipherPatterns {
            if let range = js.range(of: pattern, options: .regularExpression) {
                let line = String(js[range])
                let regex = try? NSRegularExpression(pattern: pattern)
                if let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                   match.numberOfRanges > 1,
                   let swiftRange = Range(match.range(at: 1), in: line) {
                    self.decipherFuncName = String(line[swiftRange])
                    print("[Config] decipherFuncName (\(desc)): \(self.decipherFuncName!)")
                    break
                }
            }
        }
        if self.decipherFuncName == nil {
            print("[Config] decipherFuncName: NOT FOUND after multiple patterns")
        }
        
        // n transform function name
        let nTransformPatterns: [(String, String)] = [
            (#"\.set\(["']n["'],\s*([A-Za-z0-9_$]+)(?:\.call|\.apply)?\("#, "direct-call"),
        ]
        for (pattern, desc) in nTransformPatterns {
            if let range = js.range(of: pattern, options: .regularExpression) {
                let line = String(js[range])
                let regex = try? NSRegularExpression(pattern: pattern)
                if let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                   match.numberOfRanges > 1,
                   let swiftRange = Range(match.range(at: 1), in: line) {
                    self.nTransFuncName = String(line[swiftRange])
                    print("[Config] nTransFuncName (\(desc)): \(self.nTransFuncName!)")
                    break
                }
            }
        }
        if self.nTransFuncName == nil {
            print("[Config] nTransFuncName: NOT FOUND after multiple patterns")
        }
    }
    
    private func initializeJSContext(with js: String) {
        let context = JSContext()
        context?.exceptionHandler = { _, exception in
            if let exc = exception {
                print("JS Error [mock]: \(exc.toString() ?? "")")
            }
        }
        print("[JSContext] Evaluating browser mock environment...")
        context?.evaluateScript("""
            var window = this;
            var location = {
                hostname: 'www.youtube.com',
                href: 'https://www.youtube.com/',
                protocol: 'https:',
                pathname: '/',
                search: '',
                hash: '',
                origin: 'https://www.youtube.com',
                host: 'www.youtube.com',
                port: '',
                toString: function(){ return this.href; },
                assign: function(){},
                replace: function(){},
                reload: function(){}
            };
            window.location = location;
            var navigator = {
                userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
                language: 'en-US',
                languages: ['en-US'],
                platform: 'MacIntel',
                cookieEnabled: true,
                onLine: true
            };
            var document = {
                querySelector: function(){ return null; },
                createElement: function(tag){
                    var el = {
                        style: {}, setAttribute: function(){}, appendChild: function(){},
                        classList: { add: function(){} }, removeAttribute: function(){},
                        getAttribute: function(){ return null; }, addEventListener: function(){},
                        removeEventListener: function(){}, cloneNode: function(){ return el; },
                        contains: function(){ return false; }, getBoundingClientRect: function(){ return {top:0,left:0,right:0,bottom:0,width:0,height:0}; },
                        querySelector: function(){ return null; }, querySelectorAll: function(){ return []; },
                        innerHTML: '', textContent: '', tagName: (tag||'div').toUpperCase()
                    };
                    return el;
                },
                addEventListener: function(){},
                removeEventListener: function(){},
                dispatchEvent: function(){ return true; },
                getElementById: function(){ return null; },
                getElementsByTagName: function(){ return []; },
                getElementsByClassName: function(){ return []; },
                querySelectorAll: function(){ return []; },
                location: location,
                documentElement: { style: {}, classList: { add: function(){} } },
                body: { style: {}, appendChild: function(){}, classList: { add: function(){} }, addEventListener: function(){}, removeEventListener: function(){} },
                head: { appendChild: function(){} },
                cookie: '',
                title: 'YouTube',
                createEvent: function(type){ return { initEvent: function(){}, type: type }; },
                createTextNode: function(text){ return { textContent: text, nodeType: 3 }; },
                hidden: false,
                visibilityState: 'visible',
                readyState: 'complete'
            };
            var setTimeout = function(fn, delay){ return 0; };
            var clearTimeout = function(){};
            var setInterval = function(fn, delay){ return 0; };
            var clearInterval = function(){};
            var console = { log: function(){}, error: function(){}, warn: function(){}, info: function(){}, debug: function(){} };
            var performance = { now: function(){ return Date.now(); }, timing: { navigationStart: Date.now() } };
            var screen = { width: 1920, height: 1080, colorDepth: 24, availWidth: 1920, availHeight: 1055 };
            var innerWidth = 1920;
            var innerHeight = 1080;
            var self = window;
            var top = window;
            var parent = window;
            var frames = [];

            // XHR
            var XMLHttpRequest = function(){
                this.readyState = 0;
                this.status = 0;
                this.statusText = '';
                this.responseText = '';
                this.responseXML = null;
                this.response = null;
                this.responseType = '';
                this.timeout = 0;
                this.withCredentials = false;
                this.onreadystatechange = null;
                this.onload = null;
                this.onerror = null;
                this.ontimeout = null;
                this.upload = {};
                this.open = function(method, url, async){ this.readyState = 1; };
                this.send = function(data){};
                this.setRequestHeader = function(header, value){};
                this.abort = function(){};
                this.getResponseHeader = function(header){ return null; };
                this.getAllResponseHeaders = function(){ return ''; };
                this.overrideMimeType = function(mime){};
                this.addEventListener = function(){};
                this.removeEventListener = function(){};
            };
            XMLHttpRequest.UNSENT = 0;
            XMLHttpRequest.OPENED = 1;
            XMLHttpRequest.HEADERS_RECEIVED = 2;
            XMLHttpRequest.LOADING = 3;
            XMLHttpRequest.DONE = 4;

            var fetch = function(url, options){
                return Promise.resolve({
                    ok: true, status: 200, statusText: 'OK',
                    headers: { get: function(){ return null; }, has: function(){ return false; }, forEach: function(){} },
                    json: function(){ return Promise.resolve({}); },
                    text: function(){ return Promise.resolve(''); },
                    blob: function(){ return Promise.resolve(new Blob()); },
                    arrayBuffer: function(){ return Promise.resolve(new ArrayBuffer(0)); },
                    clone: function(){ return this; },
                    body: null, bodyUsed: false, redirected: false, type: 'basic', url: ''
                });
            };
            var Headers = function(){};
            var Request = function(url, options){};
            var Response = function(body, options){ this.body = body; };
            Response.prototype.json = function(){ return Promise.resolve({}); };
            Response.prototype.text = function(){ return Promise.resolve(''); };

            var btoa = function(str){ return str; };
            var atob = function(str){ return str; };

            var localStorage = { getItem: function(){ return null; }, setItem: function(){}, removeItem: function(){}, clear: function(){}, key: function(){ return null; }, length: 0 };
            var sessionStorage = { getItem: function(){ return null; }, setItem: function(){}, removeItem: function(){}, clear: function(){}, key: function(){ return null; }, length: 0 };

            var addEventListener = function(){};
            var removeEventListener = function(){};
            var dispatchEvent = function(){ return true; };

            var Event = function(type, opts){ this.type = type; this.bubbles = (opts||{}).bubbles||false; this.cancelable = (opts||{}).cancelable||false; };
            Event.prototype.preventDefault = function(){};
            Event.prototype.stopPropagation = function(){};
            Event.prototype.stopImmediatePropagation = function(){};
            var CustomEvent = function(type, opts){ Event.call(this, type, opts); this.detail = (opts||{}).detail; };
            CustomEvent.prototype = Object.create(Event.prototype);

            var Image = function(){};
            var Blob = function(parts, opts){ this.size = 0; this.type = (opts||{}).type||''; };
            var File = function(parts, name, opts){ Blob.call(this, parts, opts); this.name = name; this.lastModified = Date.now(); };
            var FileReader = function(){};
            FileReader.prototype.readAsDataURL = function(){};
            FileReader.prototype.readAsText = function(){};
            FileReader.prototype.readAsArrayBuffer = function(){};
            FileReader.prototype.abort = function(){};
            var FileList = function(){};
            var FormData = function(){ this.append = function(){}; };

            var URLSearchParams = function(){};
            URLSearchParams.prototype.append = function(){};
            URLSearchParams.prototype.delete = function(){};
            URLSearchParams.prototype.get = function(){ return null; };
            URLSearchParams.prototype.getAll = function(){ return []; };
            URLSearchParams.prototype.has = function(){ return false; };
            URLSearchParams.prototype.set = function(){};
            URLSearchParams.prototype.toString = function(){ return ''; };

            var WebSocket = function(){};
            WebSocket.prototype.send = function(){};
            WebSocket.prototype.close = function(){};
            WebSocket.CONNECTING = 0;
            WebSocket.OPEN = 1;
            WebSocket.CLOSING = 2;
            WebSocket.CLOSED = 3;

            var Worker = function(url){};
            Worker.prototype.postMessage = function(){};
            Worker.prototype.terminate = function(){};

            var MutationObserver = function(callback){ this.observe = function(){}, this.disconnect = function(){}, this.takeRecords = function(){ return []; }; };
            var IntersectionObserver = function(callback, opts){ this.observe = function(){}, this.unobserve = function(){}, this.disconnect = function(){}, this.takeRecords = function(){ return []; }; };
            var ResizeObserver = function(callback){ this.observe = function(){}, this.unobserve = function(){}, this.disconnect = function(){}; };

            var requestAnimationFrame = function(cb){ return setTimeout(cb, 16); };
            var cancelAnimationFrame = function(id){ clearTimeout(id); };

            var matchMedia = function(query){ return { matches: false, media: query, onchange: null, addListener: function(){}, removeListener: function(){}, addEventListener: function(){}, removeEventListener: function(){} }; };
            var getComputedStyle = function(el, pseudo){ return el.style||{}; };

            var crypto = { getRandomValues: function(buf){ for(var i=0;i<buf.length;i++) buf[i]=Math.floor(Math.random()*256); return buf; }, randomUUID: function(){ return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,function(c){var r=Math.random()*16|0;return (c=='x'?r:r&0x3|0x8).toString(16);}); }, subtle: {} };

            // Common YouTube feature detection stubs
            var _yt_player = {};
        """)
        print("[JSContext] Mock evaluation complete. Now evaluating player JS...")
        context?.exceptionHandler = { _, exception in
            if let exc = exception {
                print("JS Error [player]: \(exc.toString() ?? "")")
            }
        }
        context?.evaluateScript(js)
        print("[JSContext] Player JS evaluation complete.")
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
                
                // Parse raw JSON to handle cipher objects (adaptive formats)
                let rawJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let rawStreaming = rawJSON?["streamingData"] as? [String: Any]
                let rawFormats = rawStreaming?["formats"] as? [[String: Any]] ?? []
                let rawAdaptiveFormats = rawStreaming?["adaptiveFormats"] as? [[String: Any]] ?? []
                let rawAllFormats = rawFormats + rawAdaptiveFormats
                
                func extractCipher(from rawFormat: [String: Any]) -> String? {
                    for key in ["signatureCipher", "cipher"] {
                        if let cipherStr = rawFormat[key] as? String {
                            return cipherStr
                        }
                        if let cipherObj = rawFormat[key] as? [String: String] {
                            var parts: [String] = []
                            if let u = cipherObj["url"] { parts.append("url=\(u)") }
                            if let s = cipherObj["s"] ?? cipherObj["sig"] { parts.append("s=\(s)") }
                            if let sp = cipherObj["sp"] { parts.append("sp=\(sp)") }
                            if !parts.isEmpty { return parts.joined(separator: "&") }
                        }
                    }
                    return nil
                }
                
                var allFormats = (streaming.formats ?? [])
                allFormats += (streaming.adaptiveFormats ?? [])
                
                let adaptiveSet = Set(streaming.adaptiveFormats?.map(\.itag) ?? [])
                var infos: [VideoStreamInfo] = []
                
                var urlCount = 0, cipherCount = 0, objectCipherCount = 0
                for (index, fmt) in allFormats.enumerated() {
                    var directURL: URL?
                    if let urlStr = fmt.url {
                        directURL = self?.processURL(urlStr)
                        urlCount += 1
                    } else if let cipher = fmt.signatureCipher ?? fmt.cipher {
                        directURL = self?.decipherCipher(cipher)
                        cipherCount += 1
                    } else if index < rawAllFormats.count,
                              let fallbackCipher = extractCipher(from: rawAllFormats[index]) {
                        print("[Fetch] itag \(fmt.itag): cipher extracted from JSON object")
                        directURL = self?.decipherCipher(fallbackCipher)
                        cipherCount += 1
                        objectCipherCount += 1
                    }
                    let quality = fmt.qualityLabel ?? fmt.quality ?? "Unknown"
                    infos.append(VideoStreamInfo(
                        itag: fmt.itag, quality: quality, mimeType: fmt.mimeType,
                        directURL: directURL, contentLength: Int64(fmt.contentLength ?? ""),
                        isAdaptive: adaptiveSet.contains(fmt.itag)
                    ))
                }
                let withURL = infos.filter { $0.directURL != nil }.count
                print("[Fetch] Total formats: \(allFormats.count), with url: \(urlCount), with cipher: \(cipherCount) (object: \(objectCipherCount)), produced URLs: \(withURL)")
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
        print("[Decipher] raw cipher (first 300 chars): \(cipher.prefix(300))")
        var urlStr: String?, sig: String?, sp: String?
        for pair in decoded.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                switch kv[0] {
                case "url", "u": urlStr = kv[1]
                case "s", "sig": sig = kv[1]
                case "sp": sp = kv[1]
                default: break
                }
            } else if kv.count > 2 {
                let key = kv[0]
                let val = kv.dropFirst().joined(separator: "=")
                switch key {
                case "url", "u": urlStr = val
                case "s", "sig": sig = val
                case "sp": sp = val
                default: break
                }
            }
        }
        print("[Decipher] url: \(urlStr?.prefix(80) ?? "nil"), s: \(sig?.prefix(20) ?? "nil"), sp: \(sp ?? "nil")")
        guard let urlStr = urlStr, let sig = sig, let deciphered = decipherSignature(sig) else {
            print("[Decipher] FAILED - urlStr missing: \(urlStr == nil), sig missing: \(sig == nil), decipher returned nil: \(urlStr != nil && sig != nil)")
            return nil
        }
        let param = sp ?? "sig"
        let final = urlStr.contains("?") ? "\(urlStr)&\(param)=\(deciphered)" : "\(urlStr)?\(param)=\(deciphered)"
        print("[Decipher] SUCCESS, final URL: \(final.prefix(100))...")
        return processURL(final)
    }
    
    private func decipherSignature(_ sig: String) -> String? {
        guard let ctx = jsContext, let name = decipherFuncName else {
            print("[DecipherSig] ctx nil: \(jsContext == nil), name nil: \(decipherFuncName == nil) - returning raw sig")
            return sig
        }
        let escaped = sig.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "\(name)(\"\(escaped)\")"
        let result = ctx.evaluateScript(script)
        if let str = result?.toString() {
            print("[DecipherSig] \(name)(...) -> \(str.prefix(30))...")
            return str
        } else {
            print("[DecipherSig] \(name)(...) returned nil (function missing or threw error)")
            return nil
        }
    }
    
    private func transformNParam(_ n: String) -> String? {
        guard let ctx = jsContext, let name = nTransFuncName else { return n }
        let escaped = n.replacingOccurrences(of: "\"", with: "\\\"")
        return ctx.evaluateScript("\(name)(\"\(escaped)\")")?.toString()
    }
}
