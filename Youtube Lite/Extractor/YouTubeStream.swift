// YouTubeStream.swift
// YouTube Lite
//
// Created by Antigravity on 2026-05-18.
//

import Foundation

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
