// YouTubeVideoInfo.swift
// YouTube Lite
//
// Created by Antigravity on 2026-05-18.
//

import Foundation

public struct YouTubeVideoInfo {
    public let videoId: String
    public let title: String
    public let duration: Int?         // giây
    public let visitorData: String?             // Token cho playback
    public let thumbnailUrl: URL?               // Hình nền video
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

    /// Stream audio ưu tiên tương thích với AVPlayer/iPhone trước khi ưu tiên bitrate
    public var preferredAudioStream: YouTubeStream? {
        let mp4Streams = audioStreams.filter {
            let mime = $0.mimeType.lowercased()
            return mime.contains("audio/mp4") || mime.contains("audio/m4a")
        }

        let candidates = !mp4Streams.isEmpty ? mp4Streams : audioStreams
        guard !candidates.isEmpty else { return nil }

        let preferredItags = [139, 140, 141, 599]
        for itag in preferredItags {
            if let stream = candidates.first(where: { $0.itag == itag }) {
                return stream
            }
        }

        return candidates
            .sorted {
                let lhs = $0.bitrate ?? 0
                let rhs = $1.bitrate ?? 0
                if lhs == rhs {
                    return ($0.audioSampleRate ?? "") > ($1.audioSampleRate ?? "")
                }
                return lhs > rhs
            }
            .first
    }
}
