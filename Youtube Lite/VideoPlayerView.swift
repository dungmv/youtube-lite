import SwiftUI
import AVKit
import AVFoundation
import CoreMedia

struct VideoPlayerView: View {
    let videoInfo: YouTubeVideoInfo
    @Binding var selectedStream: YouTubeStream
    
    @State private var player = AVPlayer()
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        PlayerView(player: player)
            .frame(minWidth: 640, idealWidth: 960, minHeight: 360, idealHeight: 540)
            .navigationTitle(videoInfo.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    streamSelectionMenu
                }
            }
            .onAppear {
                setupPlayer()
                loadVideo()
            }
            .onChange(of: selectedStream) {
                loadVideo()
            }
            .onDisappear {
                // Trên iOS, chỉ pause khi thực sự thoát khỏi màn hình (không phải khi ẩn app vào nền)
                #if os(iOS)
                if scenePhase != .background {
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                }
                #else
                player.pause()
                player.replaceCurrentItem(with: nil)
                #endif
            }
    }

    private func setupPlayer() {
        PlaybackManager.shared.setPlayer(player)
        
        #if os(iOS)
        player.allowsExternalPlayback = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        #endif
        
        // Theo dõi thời gian để cập nhật Now Playing
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { time in
            updateNowPlaying(currentTime: time.seconds)
        }
    }

    private func updateNowPlaying(currentTime: Double? = nil) {
        let duration = Double(videoInfo.duration ?? 0)
        let current = currentTime ?? player.currentTime().seconds
        
        PlaybackManager.shared.updateNowPlaying(
            title: videoInfo.title,
            duration: duration,
            currentTime: current,
            thumbnail: videoInfo.thumbnailUrl
        )
    }

    private var streamSelectionMenu: some View {
        Menu {
            let allStreams = videoInfo.muxedStreams + videoInfo.videoStreams + videoInfo.audioStreams
            ForEach(allStreams) { stream in
                Button(action: {
                    selectedStream = stream
                }) {
                    HStack {
                        if stream.id == selectedStream.id {
                            Image(systemName: "checkmark")
                        }
                        Text("\(stream.quality) (\(stream.mimeType.split(separator: ";").first ?? ""))")
                        if stream.isVideoOnly {
                            Text("- Video only")
                        } else if stream.isAudioOnly {
                            Text("- Audio only")
                        }
                    }
                }
            }
        } label: {
            Label("Quality: \(selectedStream.quality)", systemImage: "gearshape")
        }
    }
    
    private func loadVideo() {
        Task {
            let stream = selectedStream
            let videoURL: URL = stream.isVideoOnly ? stream.url : (stream.isAudioOnly ? (videoInfo.bestVideoStream?.url ?? stream.url) : stream.url)
            let audioURL: URL? = stream.isVideoOnly ? videoInfo.bestAudioStream?.url : (stream.isAudioOnly ? stream.url : nil)
            
            let playerItem = await createPlayerItem(videoURL: videoURL, audioURL: audioURL, visitorData: videoInfo.visitorData)
            await MainActor.run {
                player.replaceCurrentItem(with: playerItem)
                player.play()
                updateNowPlaying()
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

// MARK: - Unified Player View for iOS/macOS
#if os(iOS)
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.updatesNowPlayingInfoCenter = false // Quản lý qua PlaybackManager
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
#else
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
#endif

#Preview {
    VideoPlayerView(
        videoInfo: YouTubeVideoInfo(videoId: "abc", title: "Test", duration: 100, visitorData: nil, thumbnailUrl: nil, muxedStreams: [], videoStreams: [], audioStreams: []),
        selectedStream: .constant(YouTubeStream(itag: 18, url: URL(string: "https://example.com")!, mimeType: "video/mp4", quality: "360p", width: 640, height: 360, bitrate: 500000, audioSampleRate: nil, isAdaptive: false))
    )
}
