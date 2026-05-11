import SwiftUI
import AVKit
import AVFoundation
import CoreMedia

struct VideoPlayerView: View {
    let videoURL: URL
    let audioURL: URL?
    let visitorData: String?
    let title: String

    var body: some View {
        AVPlayerContainerView(videoURL: videoURL, audioURL: audioURL, visitorData: visitorData)
            .frame(minWidth: 640, idealWidth: 960, minHeight: 360, idealHeight: 540)
            .navigationTitle(title)
    }
}

struct AVPlayerContainerView: NSViewRepresentable {
    let videoURL: URL
    let audioURL: URL?
    let visitorData: String?

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.allowsVideoFrameAnalysis = true
        
        let player = AVPlayer()
        playerView.player = player
        
        Task {
            let playerItem = await createPlayerItem(videoURL: videoURL, audioURL: audioURL, visitorData: visitorData)
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
    
    private func createPlayerItem(videoURL: URL, audioURL: URL?, visitorData: String?) async -> AVPlayerItem {
        var headers: [String: String] = [
            "User-Agent": "com.google.android.youtube/19.29.37 (Linux; U; Android 11; en_US; Pixel 5; Build/RQ3A.210605.005)",
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/",
            "Range": "bytes=0-"
        ]
        
        if let visitorData = visitorData {
            headers["X-Goog-Visitor-Id"] = visitorData
        }

        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]

        guard let audioURL = audioURL else {
            let asset = AVURLAsset(url: videoURL, options: options)
            return AVPlayerItem(asset: asset)
        }
        
        let composition = AVMutableComposition()
        
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
        visitorData: nil,
        title: "Preview Video"
    )
}
