// YouTubeStreamExtractor.swift
// Dịch logic từ youtube-dl/youtube_dl/extractor/youtube.py
// Dùng YouTube Innertube API (android_sdkless client) để lấy stream URL
// Không cần parse HTML, không cần JS engine, không cần API key chính thức

import Foundation

// MARK: - Models

public struct YouTubeStream: Identifiable, Hashable {
    public var id: String { "\(itag)-\(isAdaptive)-\(url.absoluteString.hashValue)" }
    public let itag: Int
    public let url: URL
    public let mimeType: String
    public let quality: String
    public let width: Int?
    public let height: Int?
    public let bitrate: Int?
    public let audioSampleRate: String?
    public let isAdaptive: Bool  // true = chỉ video hoặc chỉ audio (adaptive), false = muxed (cả hai)

    public var isVideoOnly: Bool { isAdaptive && audioSampleRate == nil }
    public var isAudioOnly: Bool { isAdaptive && audioSampleRate != nil && (width == nil || width == 0) }
}

public struct YouTubeVideoInfo {
    public let videoId: String
    public let title: String
    public let duration: Int?         // giây
    public let visitorData: String?             // Token cho playback
    public let muxedStreams: [YouTubeStream]    // video + audio trong 1 file (dễ play nhất)
    public let videoStreams: [YouTubeStream]    // chỉ video (adaptive)
    public let audioStreams: [YouTubeStream]    // chỉ audio (adaptive)

    /// Stream muxed chất lượng cao nhất (không cần ghép audio riêng)
    public var bestMuxedStream: YouTubeStream? {
        muxedStreams.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
    }

    /// Stream video adaptive chất lượng cao nhất (ưu tiên mp4)
    public var bestVideoStream: YouTubeStream? {
        let mp4Streams = videoStreams.filter { $0.mimeType.contains("video/mp4") }
        if !mp4Streams.isEmpty {
            return mp4Streams.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
        }
        return videoStreams.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
    }

    /// Stream audio adaptive bitrate cao nhất (ưu tiên mp4/m4a)
    public var bestAudioStream: YouTubeStream? {
        let mp4Streams = audioStreams.filter { $0.mimeType.contains("audio/mp4") || $0.mimeType.contains("audio/m4a") }
        if !mp4Streams.isEmpty {
            return mp4Streams.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) })
        }
        return audioStreams.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) })
    }
}

public struct YouTubeVideo: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let thumbnailUrl: URL?
    public let channelName: String?
    public let duration: String?
    public let viewCount: String?
}

public enum YouTubeExtractorError: Error, LocalizedError {
    case invalidVideoID
    case networkError(Error)
    case parseError(String)
    case videoUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidVideoID: return "Video ID không hợp lệ"
        case .networkError(let e): return "Lỗi mạng: \(e.localizedDescription)"
        case .parseError(let msg): return "Lỗi parse: \(msg)"
        case .videoUnavailable(let reason): return "Video không khả dụng: \(reason)"
        }
    }
}

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
        
        if let cookies = cookies {
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
        
        if let cookies = cookies {
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

        return parseBrowseResponse(json)
    }

    /// Lấy thông tin profile của người dùng hiện tại
    public func fetchProfile() async throws -> (displayName: String?, avatarUrl: URL?) {
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
        
        if let cookies = cookies {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

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
        return parseSearchResponse(json) // Dùng chung logic tìm renderer cho browse
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
        var videos: [YouTubeVideo] = []
        
        // Tìm tất cả videoRenderer, compactVideoRenderer, gridVideoRenderer, richVideoRenderer, playlistVideoRenderer, reelItemRenderer trong toàn bộ JSON
        let videoRenderers = findAllRenderers(in: json, keys: [
            "videoRenderer", 
            "compactVideoRenderer", 
            "gridVideoRenderer", 
            "richVideoRenderer", 
            "playlistVideoRenderer", 
            "reelItemRenderer"
        ])
        print("YouTube Parse: Found \(videoRenderers.count) potential video renderers")

        for renderer in videoRenderers {
            if let video = parseVideoRenderer(renderer) {
                videos.append(video)
            }
        }

        print("YouTube Parse final videos count: \(videos.count)")
        return videos
    }


    private func parseVideoRenderer(_ renderer: [String: Any]) -> YouTubeVideo? {
        // Một số renderer dùng 'videoId' ở top level, số khác lồng trong navigationEndpoint
        var videoId: String? = renderer["videoId"] as? String
        
        if videoId == nil {
            let nav = renderer["navigationEndpoint"] as? [String: Any]
            let watch = (nav?["watchEndpoint"] as? [String: Any]) 
                ?? (nav?["reelWatchEndpoint"] as? [String: Any])
            videoId = watch?["videoId"] as? String
        }
        
        guard let id = videoId else { 
            return nil 
        }
        
        let titleText = extractText(from: renderer["title"]) 
            ?? extractText(from: renderer["headline"])
            ?? "Unknown Title"
        
        let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailUrlString = thumbnails?.last?["url"] as? String
        let thumbnailUrl = thumbnailUrlString.flatMap { URL(string: $0) }
        
        let channelName = extractText(from: renderer["longBylineText"])
            ?? extractText(from: renderer["shortBylineText"])
            ?? extractText(from: renderer["ownerText"])
        
        let lengthText = extractText(from: renderer["lengthText"])
        let viewCount = extractText(from: renderer["viewCountText"])
            ?? extractText(from: renderer["shortViewCountText"])
        
        return YouTubeVideo(
            id: id,
            title: titleText,
            thumbnailUrl: thumbnailUrl,
            channelName: channelName,
            duration: lengthText,
            viewCount: viewCount
        )
    }

    /// Helper để lấy text từ các object có cấu trúc 'simpleText' hoặc 'runs'
    private func extractText(from object: Any?) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        
        if let simpleText = dict["simpleText"] as? String {
            return simpleText
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
        
        if let cookies = cookies {
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

// MARK: - String Regex Helper

private extension String {
    func firstMatch(pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(self.startIndex..., in: self)),
              match.numberOfRanges > group else { return nil }
        let range = match.range(at: group)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: self) else { return nil }
        return String(self[swiftRange])
    }
}
