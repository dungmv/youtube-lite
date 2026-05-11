import Foundation
import AVFoundation
import MediaPlayer
import Combine

@MainActor
class PlaybackManager: ObservableObject {
    static let shared = PlaybackManager()
    
    private var nowPlayingInfo = [String: Any]()
    private weak var currentPlayer: AVPlayer?
    
    private init() {
        setupRemoteCommandCenter()
    }
    
    func setPlayer(_ player: AVPlayer) {
        self.currentPlayer = player
    }
    
    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.currentPlayer?.play()
            self.updatePlaybackRate(1.0)
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.currentPlayer?.pause()
            self.updatePlaybackRate(0.0)
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, let player = self.currentPlayer else { return .commandFailed }
            if player.rate == 0 {
                player.play()
                self.updatePlaybackRate(1.0)
            } else {
                player.pause()
                self.updatePlaybackRate(0.0)
            }
            return .success
        }
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
    }
    
    func updateNowPlaying(title: String, duration: Double, currentTime: Double, thumbnail: URL? = nil) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        
        self.nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        
        // Tải thumbnail nếu có
        if let url = thumbnail {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                if let data = data, let image = PlatformImage(data: data) {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        self.nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo
                    }
                }
            }.resume()
        }
    }
    
    func updatePlaybackRate(_ rate: Float) {
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif
