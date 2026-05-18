// YouTubeStreamExtractor.swift
// Dịch logic từ youtube-dl/youtube_dl/extractor/youtube.py
// Dùng YouTube Innertube API (android_sdkless client) để lấy stream URL
// Không cần parse HTML, không cần JS engine, không cần API key chính thức

import Foundation

// MARK: - Extractor

public final class YouTubeStreamExtractor {

    // ─── Innertube client config (android_sdkless)
    // Nguồn: youtube.py - _INNERTUBE_CLIENTS['android_sdkless']
    // Client này không yêu cầu PoToken và không yêu cầu JS player
    private static let innertubeAPIKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    private static let innertubeClientName = "ANDROID"
    private static let innertubeClientVersion = "20.10.38"
    private static let innertubeClientNameID = 3
    private static let userAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11)"

    private let session: URLSession
    private let cookies: String?

    public init(session: URLSession = .shared, cookies: String? = nil) {
        self.session = session
        self.cookies = cookies
    }

    // MARK: - Public API

    /// Lấy thông tin stream từ video ID hoặc URL YouTube
    public func extract(videoIDOrURL: String) async throws -> YouTubeVideoInfo {
        let videoID = try extractVideoID(from: videoIDOrURL)
        let playerResponse = try await fetchPlayerResponse(videoID: videoID)
        return try parsePlayerResponse(playerResponse, videoID: videoID)
    }

    /// Tìm kiếm video trên YouTube
    public func search(query: String) async throws -> [YouTubeVideo] {
        let urlString = "https://www.youtube.com/youtubei/v1/search?key=\(Self.innertubeAPIKey)"
        guard let url = URL(string: urlString) else {
            throw YouTubeExtractorError.parseError("URL API search không hợp lệ")
        }

        let body: [String: Any] = [
            "query": query,
            "context": [
                "client": [
                    "clientName": Self.innertubeClientName,
                    "clientVersion": Self.innertubeClientVersion,
                    "androidSdkVersion": 30,
                    "osName": "Android",
                    "osVersion": "11",
                    "hl": "en",
                    "gl": "US",
                ],
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(Self.innertubeClientNameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.innertubeClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        
        if let cookies = cookies, !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YouTubeExtractorError.networkError(URLError(.badServerResponse))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeExtractorError.parseError("Không parse được JSON search response")
        }

        print("YouTube Search Response Keys: \(json.keys)")
        return parseSearchResponse(json)
    }

    /// Lấy danh sách video đề xuất (Home feed)
    public func recommendations() async throws -> [YouTubeVideo] {
        let urlString = "https://www.youtube.com/youtubei/v1/browse?key=\(Self.innertubeAPIKey)"
        guard let url = URL(string: urlString) else {
            throw YouTubeExtractorError.parseError("URL API browse không hợp lệ")
        }

        let body: [String: Any] = [
            "browseId": "FEwhat_to_watch",
            "context": [
                "client": [
                    "clientName": Self.innertubeClientName,
                    "clientVersion": Self.innertubeClientVersion,
                    "androidSdkVersion": 30,
                    "osName": "Android",
                    "osVersion": "11",
                    "hl": "en",
                    "gl": "US",
                ],
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(Self.innertubeClientNameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.innertubeClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        
        if let cookies = cookies, !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YouTubeExtractorError.networkError(URLError(.badServerResponse))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeExtractorError.parseError("Không parse được JSON browse response")
        }

        let videos = parseBrowseResponse(json)
        
        // GRACEFUL FALLBACK: Nếu không lấy được video (ví dụ do tài khoản khách chưa đăng nhập bị YouTube chặn feed)
        // Chúng ta sẽ tự động tìm kiếm các video trending phổ biến để lấp đầy trang chủ!
        if videos.isEmpty {
            print("YouTube Parse: Home feed is empty. Triggering trending fallback...")
            do {
                return try await search(query: "trending")
            } catch {
                print("YouTube Parse: Trending fallback search failed: \(error)")
                return []
            }
        }
        
        return videos
    }

    /// Lấy thông tin profile của người dùng hiện tại
    public func fetchProfile() async throws -> (displayName: String?, avatarUrl: URL?) {
        guard let cookies = cookies, !cookies.isEmpty else {
            print("YouTube Profile: Cookies is nil or empty, skipping guide API fetch.")
            return (nil, nil)
        }
        
        let urlString = "https://www.youtube.com/youtubei/v1/guide?key=\(Self.innertubeAPIKey)"
        guard let url = URL(string: urlString) else {
            throw YouTubeExtractorError.parseError("URL API guide không hợp lệ")
        }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": Self.innertubeClientName,
                    "clientVersion": Self.innertubeClientVersion,
                    "androidSdkVersion": 30,
                    "osName": "Android",
                    "osVersion": "11",
                    "hl": "en",
                    "gl": "US",
                ],
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(Self.innertubeClientNameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.innertubeClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        
        request.setValue(cookies, forHTTPHeaderField: "Cookie")

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return (nil, nil)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        var displayName: String? = nil
        var avatarUrl: URL? = nil

        // Tìm tất cả các renderer có khả năng chứa thông tin profile
        let profileRenderers = findAllRenderers(in: json, keys: [
            "activeAccountHeaderRenderer", 
            "accountItemRenderer", 
            "accountThumbnail",
            "identityRenderer"
        ])
        
        for renderer in profileRenderers {
            // 1. Lấy Display Name
            if displayName == nil {
                displayName = extractText(from: renderer["accountName"])
                    ?? extractText(from: renderer["channelName"])
                    ?? extractText(from: renderer["headerText"])
            }
            
            // 2. Lấy Avatar URL
            if avatarUrl == nil {
                // Thử accountPhoto, thumbnail hoặc thumbnails trực tiếp
                let photo = (renderer["accountPhoto"] as? [String: Any]) 
                    ?? (renderer["thumbnail"] as? [String: Any]) 
                    ?? renderer
                
                let thumbnails = photo["thumbnails"] as? [[String: Any]]
                let thumbnailUrlString = thumbnails?.last?["url"] as? String
                avatarUrl = thumbnailUrlString.flatMap { URL(string: $0) }
            }
            
            if displayName != nil && avatarUrl != nil {
                break
            }
        }
        
        print("YouTube Profile Fetched: \(displayName ?? "nil"), \(avatarUrl?.absoluteString ?? "nil")")
        return (displayName, avatarUrl)
    }

    private func parseBrowseResponse(_ json: [String: Any]) -> [YouTubeVideo] {
        return extractVideos(from: json)
    }

    /// Tìm tất cả các dictionary có key nằm trong danh sách `keys`
    private func findAllRenderers(in json: Any, keys: [String]) -> [[String: Any]] {
        var results: [[String: Any]] = []
        
        if let dict = json as? [String: Any] {
            for (key, value) in dict {
                if keys.contains(key), let renderer = value as? [String: Any] {
                    results.append(renderer)
                } else {
                    results.append(contentsOf: findAllRenderers(in: value, keys: keys))
                }
            }
        } else if let array = json as? [Any] {
            for item in array {
                results.append(contentsOf: findAllRenderers(in: item, keys: keys))
            }
        }
        
        return results
    }

    private func parseSearchResponse(_ json: [String: Any]) -> [YouTubeVideo] {
        return extractVideos(from: json)
    }

    private func extractVideos(from json: Any) -> [YouTubeVideo] {
        var videos: [YouTubeVideo] = []
        var seenIDs = Set<String>()
        
        func traverse(_ val: Any) {
            if let dict = val as? [String: Any] {
                if let video = parseVideoFromDictionary(dict) {
                    if !seenIDs.contains(video.id) {
                        videos.append(video)
                        seenIDs.insert(video.id)
                    }
                }
                
                for (_, value) in dict {
                    traverse(value)
                }
            } else if let array = val as? [Any] {
                for item in array {
                    traverse(item)
                }
            }
        }
        
        traverse(json)
        print("YouTube Parse final videos count: \(videos.count)")
        return videos
    }

    private func parseVideoFromDictionary(_ dict: [String: Any]) -> YouTubeVideo? {
        var videoId: String? = dict["videoId"] as? String
        
        if videoId == nil {
            let nav = dict["navigationEndpoint"] as? [String: Any]
                ?? dict["onTap"] as? [String: Any]
                ?? dict["endpoint"] as? [String: Any]
                ?? dict["serviceEndpoint"] as? [String: Any]
                ?? dict["command"] as? [String: Any]
            
            let watch = (nav?["watchEndpoint"] as? [String: Any])
                ?? (nav?["reelWatchEndpoint"] as? [String: Any])
                ?? (nav?["watchCommand"] as? [String: Any])
                
            videoId = watch?["videoId"] as? String
        }
        
        guard let id = videoId, id.count == 11 else {
            return nil
        }
        
        var titleText: String? = nil
        if let titleObj = dict["title"] ?? dict["headline"] ?? dict["titleText"] {
            titleText = extractText(from: titleObj)
        }
        if titleText == nil {
            titleText = dict["title"] as? String
                ?? dict["headline"] as? String
                ?? dict["titleText"] as? String
        }
        
        // SAFETY GUARD: If there is no title, it's a configuration or non-video element
        guard let title = titleText, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        
        var thumbnailUrl: URL? = nil
        if let thumbnailDict = dict["thumbnail"] as? [String: Any] ?? dict["thumbnails"] as? [String: Any] ?? dict["image"] as? [String: Any] {
            if let thumbnails = thumbnailDict["thumbnails"] as? [[String: Any]], let urlStr = thumbnails.last?["url"] as? String {
                thumbnailUrl = URL(string: urlStr)
            } else if let sources = thumbnailDict["sources"] as? [[String: Any]], let urlStr = sources.last?["url"] as? String {
                var correctedUrl = urlStr
                if correctedUrl.hasPrefix("//") {
                    correctedUrl = "https:" + correctedUrl
                }
                thumbnailUrl = URL(string: correctedUrl)
            }
        }
        if thumbnailUrl == nil {
            if let urlStr = dict["thumbnailUrl"] as? String ?? dict["thumbnail"] as? String {
                thumbnailUrl = URL(string: urlStr)
            }
        }
        
        var channelName: String? = nil
        if let channelObj = dict["longBylineText"] ?? dict["shortBylineText"] ?? dict["ownerText"] ?? dict["author"] ?? dict["channelName"] {
            channelName = extractText(from: channelObj)
        }
        if channelName == nil {
            channelName = dict["channelName"] as? String
                ?? dict["author"] as? String
                ?? dict["ownerText"] as? String
        }
        
        var duration: String? = nil
        if let lenObj = dict["lengthText"] ?? dict["duration"] ?? dict["durationText"] {
            duration = extractText(from: lenObj)
        }
        if duration == nil {
            duration = dict["lengthText"] as? String
                ?? dict["duration"] as? String
                ?? dict["durationText"] as? String
        }
        
        var viewCount: String? = nil
        if let viewObj = dict["viewCountText"] ?? dict["shortViewCountText"] ?? dict["viewCount"] {
            viewCount = extractText(from: viewObj)
        }
        if viewCount == nil {
            viewCount = dict["viewCountText"] as? String
                ?? dict["shortViewCountText"] as? String
                ?? dict["viewCount"] as? String
        }
        
        return YouTubeVideo(
            id: id,
            title: title,
            thumbnailUrl: thumbnailUrl,
            channelName: channelName,
            duration: duration,
            viewCount: viewCount
        )
    }

    /// Helper để lấy text từ các object có cấu trúc 'simpleText' hoặc 'runs'
    private func extractText(from object: Any?) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        
        if let simpleText = dict["simpleText"] as? String {
            return simpleText
        }
        
        if let content = dict["content"] as? String {
            return content
        }
        
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        
        if let accessibility = dict["accessibility"] as? [String: Any],
           let label = (accessibility["accessibilityData"] as? [String: Any])?["label"] as? String {
            return label
        }
        
        return nil
    }

    // MARK: - Step 1: Extract Video ID

    /// Trích xuất video ID từ nhiều dạng URL YouTube khác nhau
    /// Nguồn: youtube.py - _VALID_URL regex
    private func extractVideoID(from input: String) throws -> String {
        // Nếu input là raw ID (11 ký tự)
        if input.range(of: #"^[a-zA-Z0-9_-]{11}$"#, options: .regularExpression) != nil {
            return input
        }

        // Các pattern URL YouTube phổ biến
        let patterns = [
            #"(?:https?://)?(?:www\.)?youtube\.com/watch\?.*v=([a-zA-Z0-9_-]{11})"#,
            #"(?:https?://)?(?:www\.)?youtu\.be/([a-zA-Z0-9_-]{11})"#,
            #"(?:https?://)?(?:www\.)?youtube\.com/embed/([a-zA-Z0-9_-]{11})"#,
            #"(?:https?://)?(?:www\.)?youtube\.com/v/([a-zA-Z0-9_-]{11})"#,
            #"(?:https?://)?(?:www\.)?youtube\.com/shorts/([a-zA-Z0-9_-]{11})"#,
        ]

        for pattern in patterns {
            if let match = input.firstMatch(pattern: pattern, group: 1) {
                return match
            }
        }

        throw YouTubeExtractorError.invalidVideoID
    }

    // MARK: - Step 2: Fetch Player Response (Innertube API)

    /// Gọi YouTube Innertube API /youtubei/v1/player
    /// Nguồn: youtube.py - _extract_player_response(), _call_api()
    /// API này trả về JSON chứa toàn bộ thông tin stream
    private func fetchPlayerResponse(videoID: String) async throws -> [String: Any] {
        let urlString = "https://www.youtube.com/youtubei/v1/player?key=\(Self.innertubeAPIKey)"
        guard let url = URL(string: urlString) else {
            throw YouTubeExtractorError.parseError("URL API không hợp lệ")
        }

        // Body request giả lập Android YouTube app
        // Nguồn: youtube.py - _INNERTUBE_CLIENTS['android_sdkless']['INNERTUBE_CONTEXT']
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": Self.innertubeClientName,
                    "clientVersion": Self.innertubeClientVersion,
                    "androidSdkVersion": 30,
                    "osName": "Android",
                    "osVersion": "11",
                    "hl": "en",
                    "gl": "US",
                ],
            ],
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                ],
            ],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Header giả lập client Android
        // Nguồn: youtube.py - _INNERTUBE_CONTEXT_CLIENT_NAME header
        request.setValue(String(Self.innertubeClientNameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.innertubeClientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        
        if let cookies = cookies, !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeExtractorError.networkError(URLError(.badServerResponse))
        }
        
        if httpResponse.statusCode != 200 {
            print("YouTube API Error: HTTP \(httpResponse.statusCode)")
            if let errorBody = String(data: data, encoding: .utf8) {
                print("Error body: \(errorBody)")
            }
            throw YouTubeExtractorError.networkError(NSError(domain: "YouTubeAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "YouTube API trả về lỗi HTTP \(httpResponse.statusCode)"]))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeExtractorError.parseError("Không parse được JSON response")
        }

        return json
    }

    // MARK: - Step 3: Parse Player Response → Stream URLs

    /// Parse JSON response để lấy danh sách stream URL
    /// Nguồn: youtube.py - _extract_stream_formats_from_manifest(),
    ///         _parse_stream_format(), phần xử lý streamingData
    private func parsePlayerResponse(_ response: [String: Any], videoID: String) throws -> YouTubeVideoInfo {

        // Kiểm tra trạng thái video
        if let playabilityStatus = response["playabilityStatus"] as? [String: Any] {
            let status = playabilityStatus["status"] as? String ?? ""
            if status == "ERROR" || status == "LOGIN_REQUIRED" || status == "UNPLAYABLE" {
                let reason = playabilityStatus["reason"] as? String
                    ?? (playabilityStatus["messages"] as? [String])?.first
                    ?? status
                throw YouTubeExtractorError.videoUnavailable(reason)
            }
        }

        // Lấy title
        let title: String
        if let videoDetails = response["videoDetails"] as? [String: Any],
           let t = videoDetails["title"] as? String {
            title = t
        } else {
            title = videoID
        }

        // Lấy duration
        let duration: Int?
        if let videoDetails = response["videoDetails"] as? [String: Any],
           let dStr = videoDetails["lengthSeconds"] as? String {
            duration = Int(dStr)
        } else {
            duration = nil
        }

        // Lấy thumbnail
        var thumbnailUrl: URL? = nil
        if let videoDetails = response["videoDetails"] as? [String: Any],
           let thumbnails = (videoDetails["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
           let urlStr = thumbnails.last?["url"] as? String {
            thumbnailUrl = URL(string: urlStr)
        }

        // Lấy streamingData
        guard let streamingData = response["streamingData"] as? [String: Any] else {
            throw YouTubeExtractorError.parseError("Không tìm thấy streamingData")
        }

        var muxedStreams: [YouTubeStream] = []
        var videoStreams: [YouTubeStream] = []
        var audioStreams: [YouTubeStream] = []

        // formats = video muxed (video + audio)
        // Nguồn: youtube.py phần xử lý 'formats' trong streamingData
        if let formats = streamingData["formats"] as? [[String: Any]] {
            for fmt in formats {
                if let stream = parseStreamFormat(fmt, isAdaptive: false) {
                    // Lọc bỏ WebM cho muxed streams
                    if stream.mimeType.lowercased().contains("webm") {
                        continue
                    }
                    muxedStreams.append(stream)
                }
            }
        }

        // adaptiveFormats = tách biệt video-only và audio-only
        // Nguồn: youtube.py phần xử lý 'adaptiveFormats' trong streamingData
        if let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] {
            for fmt in adaptiveFormats {
                guard let stream = parseStreamFormat(fmt, isAdaptive: true) else { continue }
                
                // AVFoundation (AVPlayer) không hỗ trợ tốt WebM/VP9 mặc định
                // Lọc bỏ WebM để tránh lỗi -11828 "Cannot Open"
                let mime = stream.mimeType.lowercased()
                if mime.contains("webm") {
                    continue
                }

                if mime.hasPrefix("audio/") {
                    audioStreams.append(stream)
                } else {
                    videoStreams.append(stream)
                }
            }
        }

        let visitorData = (response["responseContext"] as? [String: Any])?["visitorData"] as? String

        return YouTubeVideoInfo(
            videoId: videoID,
            title: title,
            duration: duration,
            visitorData: visitorData,
            thumbnailUrl: thumbnailUrl,
            muxedStreams: muxedStreams,
            videoStreams: videoStreams,
            audioStreams: audioStreams
        )
    }

    /// Parse một format object thành YouTubeStream
    /// Nguồn: youtube.py - _parse_stream_format()
    private func parseStreamFormat(_ fmt: [String: Any], isAdaptive: Bool) -> YouTubeStream? {
        // Lấy URL trực tiếp
        // Với android_sdkless client, URL thường không bị obfuscate (không có signatureCipher)
        // Nguồn: youtube.py - url = fmt.get('url')
        guard let urlString = fmt["url"] as? String,
              let url = URL(string: urlString) else {
            // signatureCipher/cipher: bỏ qua vì android_sdkless thường không dùng
            // Nếu cần handle, cần implement JS deobfuscation riêng
            return nil
        }

        guard let itag = fmt["itag"] as? Int else { return nil }

        let mimeType = fmt["mimeType"] as? String ?? "video/mp4"
        let quality = fmt["qualityLabel"] as? String
            ?? fmt["quality"] as? String
            ?? "unknown"

        let width = fmt["width"] as? Int
        let height = fmt["height"] as? Int
        let bitrate = fmt["bitrate"] as? Int
        let audioSampleRate = fmt["audioSampleRate"] as? String

        return YouTubeStream(
            itag: itag,
            url: url,
            mimeType: mimeType,
            quality: quality,
            width: width,
            height: height,
            bitrate: bitrate,
            audioSampleRate: audioSampleRate,
            isAdaptive: isAdaptive
        )
    }
}
