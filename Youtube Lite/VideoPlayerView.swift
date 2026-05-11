import SwiftUI
import AVKit
import AVFoundation
import CoreMedia

struct VideoPlayerView: View {
    let videoURL: URL
    let audioURL: URL?
    let visitorData: String?
    let title: String
    
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .frame(minWidth: 640, idealWidth: 960, minHeight: 360, idealHeight: 540)
            .navigationTitle(title)
            .onAppear {
                loadVideo()
            }
            .onDisappear {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
    }
    
    private func loadVideo() {
        Task {
            let playerItem = await createPlayerItem(videoURL: videoURL, audioURL: audioURL, visitorData: visitorData)
            await MainActor.run {
                player.replaceCurrentItem(with: playerItem)
                player.play()
            }
        }
    }
    
    private func createPlayerItem(videoURL: URL, audioURL: URL?, visitorData: String?) async -> AVPlayerItem {
        // Sử dụng User-Agent chính xác của Android client để tránh 403 Forbidden
        let userAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 11)"
        
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/"
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
            // Load tracks đồng thời để nhanh hơn
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            async let videoDuration = videoAsset.load(.duration)
            async let audioDuration = audioAsset.load(.duration)

            let vTracks = try await videoTracks
            let aTracks = try await audioTracks
            let vDur = try await videoDuration
            let aDur = try await audioDuration
            
            let duration = CMTimeMinimum(vDur, aDur)
            
            // Thêm video track
            if let videoTrack = vTracks.first {
                let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compositionVideoTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
            }
            
            // Thêm audio track
            if let audioTrack = aTracks.first {
                let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compositionAudioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
            }
            
            return AVPlayerItem(asset: composition)
        } catch {
            print("Lỗi muxing: \(error.localizedDescription). Thử phát không headers...")
            // Fallback 1: Thử lại không có headers (đôi khi YouTube cho phép nếu URL đã có signature)
            let simpleVideoAsset = AVURLAsset(url: videoURL)
            do {
                let vTracks = try await simpleVideoAsset.loadTracks(withMediaType: .video)
                if !vTracks.isEmpty {
                    return AVPlayerItem(asset: simpleVideoAsset)
                }
            } catch {
                print("Fallback không headers cũng thất bại: \(error.localizedDescription)")
            }
            
            // Fallback 2: Quay lại video ban đầu (dù lỗi)
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
