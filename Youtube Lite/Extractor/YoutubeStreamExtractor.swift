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
    public let muxedStreams: [YouTubeStream]    // video + audio trong 1 file (dễ play nhất)
    public let videoStreams: [YouTubeStream]    // chỉ video (adaptive)
    public let audioStreams: [YouTubeStream]    // chỉ audio (adaptive)

    /// Stream muxed chất lượng cao nhất (không cần ghép audio riêng)
    public var bestMuxedStream: YouTubeStream? {
        muxedStreams.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
    }

    /// Stream video adaptive chất lượng cao nhất
    public var bestVideoStream: YouTubeStream? {
        videoStreams.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
    }

    /// Stream audio adaptive bitrate cao nhất
    public var bestAudioStream: YouTubeStream? {
        audioStreams.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) })
    }
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
    private static let userAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Lấy thông tin stream từ video ID hoặc URL YouTube
    public func extract(videoIDOrURL: String) async throws -> YouTubeVideoInfo {
        let videoID = try extractVideoID(from: videoIDOrURL)
        let playerResponse = try await fetchPlayerResponse(videoID: videoID)
        return try parsePlayerResponse(playerResponse, videoID: videoID)
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
            #"(?:youtube\.com/watch\?.*v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/|youtube\.com/shorts/)([a-zA-Z0-9_-]{11})"#,
            #"youtube\.com/.*[?&]v=([a-zA-Z0-9_-]{11})"#,
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

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw YouTubeExtractorError.networkError(
                URLError(.badServerResponse)
            )
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
                    muxedStreams.append(stream)
                }
            }
        }

        // adaptiveFormats = tách biệt video-only và audio-only
        // Nguồn: youtube.py phần xử lý 'adaptiveFormats' trong streamingData
        if let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]] {
            for fmt in adaptiveFormats {
                guard let stream = parseStreamFormat(fmt, isAdaptive: true) else { continue }
                let mime = stream.mimeType.lowercased()
                if mime.hasPrefix("audio/") {
                    audioStreams.append(stream)
                } else {
                    videoStreams.append(stream)
                }
            }
        }

        return YouTubeVideoInfo(
            videoId: videoID,
            title: title,
            duration: duration,
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

// MARK: - Usage Example

/*
 // Cách dùng trong SwiftUI / async context:

 let extractor = YouTubeStreamExtractor()

 do {
     let info = try await extractor.extract(videoIDOrURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

     print("Title:", info.title)
     print("Duration:", info.duration ?? 0, "giây")

     // Stream dễ play nhất (có cả video + audio):
     if let best = info.bestMuxedStream {
         print("Best muxed URL:", best.url)
         print("Quality:", best.quality)
         // → Dùng trực tiếp với AVPlayer
         let player = AVPlayer(url: best.url)
     }

     // Nếu muốn chất lượng cao hơn (cần ghép audio riêng):
     if let bestVideo = info.bestVideoStream, let bestAudio = info.bestAudioStream {
         print("Best video:", bestVideo.url, bestVideo.quality)
         print("Best audio:", bestAudio.url, bestAudio.bitrate ?? 0, "bps")
     }

 } catch {
     print("Lỗi:", error.localizedDescription)
 }
*/
