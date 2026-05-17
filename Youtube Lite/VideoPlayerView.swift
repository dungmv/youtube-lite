import SwiftUI
import AVKit
import AVFoundation
import CoreMedia
import Combine

// MARK: - Video Player ViewModel (MVVM)
@MainActor
class VideoPlayerViewModel: ObservableObject {
    let videoInfo: YouTubeVideoInfo
    @Published var selectedStream: YouTubeStream {
        didSet {
            loadVideo()
        }
    }
    
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    
    let playbackManager = PlaybackManager.shared
    private var timeObserverToken: Any?
    
    init(videoInfo: YouTubeVideoInfo, selectedStream: YouTubeStream) {
        self.videoInfo = videoInfo
        self.selectedStream = selectedStream
    }
    
    func onAppear() {
        setupPlayer()
        loadVideo()
    }
    
    func onDisappear() {
        if let token = timeObserverToken {
            playbackManager.player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        
        #if os(iOS)
        AppDelegate.orientationController.setInlinePlayerMode()
        #endif
    }
    
    private func setupPlayer() {
        if timeObserverToken == nil {
            timeObserverToken = playbackManager.player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                queue: .main
            ) { [weak self] time in
                guard let self = self else { return }
                self.updateNowPlaying(currentTime: time.seconds)
            }
        }
    }
    
    private func updateNowPlaying(currentTime: Double? = nil) {
        let duration = Double(videoInfo.duration ?? 0)
        let current = currentTime ?? playbackManager.player.currentTime().seconds
        
        playbackManager.updateNowPlaying(
            title: videoInfo.title,
            duration: duration,
            currentTime: current,
            thumbnail: videoInfo.thumbnailUrl
        )
    }
    
    func loadVideo() {
        isLoading = true
        errorMessage = nil
        
        Task {
            let stream = selectedStream
            if !playbackManager.shouldReload(videoID: videoInfo.videoId, streamID: stream.id) {
                if playbackManager.player.timeControlStatus != .playing {
                    playbackManager.player.play()
                }
                updateNowPlaying()
                self.isLoading = false
                return
            }

            let videoURL: URL = stream.isVideoOnly ? stream.url : (stream.isAudioOnly ? (videoInfo.bestVideoStream?.url ?? stream.url) : stream.url)
            let audioURL: URL? = stream.isVideoOnly ? videoInfo.bestAudioStream?.url : (stream.isAudioOnly ? stream.url : nil)

            let playerItem: AVPlayerItem
            if stream.isAudioOnly {
                let headers = makeHTTPHeaders(visitorData: videoInfo.visitorData)
                let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                playerItem = AVPlayerItem(asset: asset)
            } else {
                playerItem = await createPlayerItem(videoURL: videoURL, audioURL: audioURL, visitorData: videoInfo.visitorData)
            }

            playbackManager.player.replaceCurrentItem(with: playerItem)
            playbackManager.markLoaded(videoID: videoInfo.videoId, streamID: stream.id)
            playbackManager.player.play()
            updateNowPlaying()
            self.isLoading = false
        }
    }

    private func makeHTTPHeaders(visitorData: String?) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "com.google.android.youtube/20.10.38 (Linux; U; Android 11)",
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/"
        ]

        if let visitorData = visitorData {
            headers["X-Goog-Visitor-Id"] = visitorData
        }

        return headers
    }
    
    private func createPlayerItem(videoURL: URL, audioURL: URL?, visitorData: String?) async -> AVPlayerItem {
        let headers = makeHTTPHeaders(visitorData: visitorData)
        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]

        guard let audioURL = audioURL else {
            let asset = AVURLAsset(url: videoURL, options: options)
            return AVPlayerItem(asset: asset)
        }
        
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL, options: options)
        let audioAsset = AVURLAsset(url: audioURL, options: options)
        
        do {
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            async let videoDuration = videoAsset.load(.duration)
            async let audioDuration = audioAsset.load(.duration)

            let vTracks = try await videoTracks
            let aTracks = try await audioTracks
            let vDur = try await videoDuration
            let aDur = try await audioDuration

            let metadataDuration: CMTime? = {
                guard let seconds = videoInfo.duration, seconds > 0 else { return nil }
                return CMTime(seconds: Double(seconds), preferredTimescale: 600)
            }()
            let duration = metadataDuration ?? CMTimeMinimum(vDur, aDur)
            
            if let videoTrack = vTracks.first {
                let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compositionVideoTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
            }
            
            if let audioTrack = aTracks.first {
                let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compositionAudioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
            }
            
            return AVPlayerItem(asset: composition)
        } catch {
            print("Lỗi muxing: \(error.localizedDescription). Thử phát không headers...")
            let simpleVideoAsset = AVURLAsset(url: videoURL)
            do {
                let vTracks = try await simpleVideoAsset.loadTracks(withMediaType: .video)
                if !vTracks.isEmpty {
                    return AVPlayerItem(asset: simpleVideoAsset)
                }
            } catch {
                print("Fallback không headers cũng thất bại: \(error.localizedDescription)")
            }
            
            let asset = AVURLAsset(url: videoURL, options: options)
            return AVPlayerItem(asset: asset)
        }
    }
}

// MARK: - Video Player Router View
struct VideoPlayerView: View {
    let videoInfo: YouTubeVideoInfo
    @Binding var selectedStream: YouTubeStream
    
    var body: some View {
        #if os(macOS)
        MacVideoPlayerView(videoInfo: videoInfo, selectedStream: $selectedStream)
        #else
        iOSVideoPlayerView(videoInfo: videoInfo, selectedStream: $selectedStream)
        #endif
    }
}

// MARK: - macOS Video Player View
#if os(macOS)
struct MacVideoPlayerView: View {
    @StateObject private var viewModel: VideoPlayerViewModel
    @Binding var selectedStream: YouTubeStream
    
    init(videoInfo: YouTubeVideoInfo, selectedStream: Binding<YouTubeStream>) {
        self._selectedStream = selectedStream
        self._viewModel = StateObject(wrappedValue: VideoPlayerViewModel(videoInfo: videoInfo, selectedStream: selectedStream.wrappedValue))
    }
    
    var body: some View {
        ZStack {
            MacPlayerView(player: viewModel.playbackManager.player)
                .background(Color.black)
            
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 360, idealHeight: 540)
        .navigationTitle(viewModel.videoInfo.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                streamSelectionMenu
            }
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: selectedStream) { _, newStream in
            viewModel.selectedStream = newStream
        }
        .onChange(of: viewModel.selectedStream) { _, newStream in
            selectedStream = newStream
        }
    }
    
    private var streamSelectionMenu: some View {
        Menu {
            let allStreams = viewModel.videoInfo.muxedStreams + viewModel.videoInfo.videoStreams + viewModel.videoInfo.audioStreams
            ForEach(allStreams) { stream in
                Button(action: {
                    viewModel.selectedStream = stream
                }) {
                    HStack {
                        if stream.id == viewModel.selectedStream.id {
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
            Label("Quality: \(viewModel.selectedStream.quality)", systemImage: "gearshape")
        }
    }
}

struct MacPlayerView: NSViewRepresentable {
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

// MARK: - iOS Video Player View
#if os(iOS)
struct iOSVideoPlayerView: View {
    @StateObject private var viewModel: VideoPlayerViewModel
    @Binding var selectedStream: YouTubeStream
    
    init(videoInfo: YouTubeVideoInfo, selectedStream: Binding<YouTubeStream>) {
        self._selectedStream = selectedStream
        self._viewModel = StateObject(wrappedValue: VideoPlayerViewModel(videoInfo: videoInfo, selectedStream: selectedStream.wrappedValue))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                iOSPlayerView(player: viewModel.playbackManager.player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                
                if viewModel.isLoading {
                    ProgressView()
                        .transition(.opacity)
                }
            }
            
            // Sleek cinematic details below player
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.videoInfo.title)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .lineLimit(3)
                        
                        HStack(spacing: 12) {
                            if let duration = viewModel.videoInfo.duration {
                                Label("\(duration / 60)m \(duration % 60)s", systemImage: "clock")
                            }
                            Text("•")
                            Label("High Quality", systemImage: "video.badge.checkmark")
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .padding(.horizontal)
                    .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
                    
                    Spacer()
                }
                .padding(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationTitle("Playing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                streamSelectionMenu
            }
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: selectedStream) { _, newStream in
            viewModel.selectedStream = newStream
        }
        .onChange(of: viewModel.selectedStream) { _, newStream in
            selectedStream = newStream
        }
    }
    
    private var streamSelectionMenu: some View {
        Menu {
            let allStreams = viewModel.videoInfo.muxedStreams + viewModel.videoInfo.videoStreams + viewModel.videoInfo.audioStreams
            ForEach(allStreams) { stream in
                Button(action: {
                    viewModel.selectedStream = stream
                }) {
                    HStack {
                        if stream.id == viewModel.selectedStream.id {
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
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundColor(.accentColor)
        }
    }
}

struct iOSPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.updatesNowPlayingInfoCenter = false
        AppDelegate.orientationController.setInlinePlayerMode()
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
        uiViewController.videoGravity = .resizeAspect
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            AppDelegate.orientationController.setFullscreenPlayerMode()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { _ in
                AppDelegate.orientationController.setInlinePlayerMode()
            }
        }
    }
}
#endif
