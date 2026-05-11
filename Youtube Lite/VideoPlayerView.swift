import SwiftUI
import AVKit
import AVFoundation
import CoreMedia

struct VideoPlayerView: View {
    let videoURL: URL
    let audioURL: URL?
    let title: String

    var body: some View {
        AVPlayerContainerView(videoURL: videoURL, audioURL: audioURL)
            .frame(minWidth: 640, idealWidth: 960, minHeight: 360, idealHeight: 540)
            .navigationTitle(title)
    }
}

struct AVPlayerContainerView: NSViewRepresentable {
    let videoURL: URL
    let audioURL: URL?

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.allowsVideoFrameAnalysis = true
        
        let player = AVPlayer()
        playerView.player = player
        
        Task {
            let playerItem = await createPlayerItem(videoURL: videoURL, audioURL: audioURL)
            await MainActor.run {
                player.replaceCurrentItem(with: playerItem)
                player.play()
            }
        }
        
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
    
    private func createPlayerItem(videoURL: URL, audioURL: URL?) async -> AVPlayerItem {
        guard let audioURL = audioURL else {
            let headers = ["User-Agent": "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"]
            let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
            let asset = AVURLAsset(url: videoURL, options: options)
            return AVPlayerItem(asset: asset)
        }
        
        let composition = AVMutableComposition()
        
        let headers = ["User-Agent": "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"]
        let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        
        let videoAsset = AVURLAsset(url: videoURL, options: options)
        let audioAsset = AVURLAsset(url: audioURL, options: options)
        
        do {
            // Thêm video track
            let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first
            if let videoTrack = videoTrack {
                let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compositionVideoTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration)), of: videoTrack, at: .zero)
            }
            
            // Thêm audio track
            let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
            if let audioTrack = audioTrack {
                let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compositionAudioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: try await audioAsset.load(.duration)), of: audioTrack, at: .zero)
            }
            
            return AVPlayerItem(asset: composition)
        } catch {
            print("Lỗi muxing: \(error)")
            let asset = AVURLAsset(url: videoURL, options: options)
            return AVPlayerItem(asset: asset)
        }
    }
}

#Preview {
    VideoPlayerView(
        videoURL: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
        audioURL: nil,
        title: "Preview Video"
    )
}
