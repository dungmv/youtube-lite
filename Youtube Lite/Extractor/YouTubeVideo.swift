// YouTubeVideo.swift
// YouTube Lite
//
// Created by Antigravity on 2026-05-18.
//

import Foundation

public struct YouTubeVideo: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let thumbnailUrl: URL?
    public let channelName: String?
    public let duration: String?
    public let viewCount: String?
}
