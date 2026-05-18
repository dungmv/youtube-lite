// YouTubeExtractorError.swift
// YouTube Lite
//
// Created by Antigravity on 2026-05-18.
//

import Foundation

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
