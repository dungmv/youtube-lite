import SwiftUI
import AVKit
import AVFoundation
import CoreMedia
import Combine

#if os(iOS)
import UIKit
#endif

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
    private var sourceAssets: [AVURLAsset] = []
    private var playerItemObserver: NSKeyValueObservation?
    private var pendingSeekTime: Double?
    private var pendingResumeRate: Float?
    private var failedAudioStreamIDs = Set<String>()
    private var loadGeneration = 0
    #if os(iOS)
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var foregroundPreferredStream: YouTubeStream?
    private var isSwitchingForBackgroundPlayback = false
    private var isBackgroundPlaybackMode = false
    #endif
    
    init(videoInfo: YouTubeVideoInfo, selectedStream: YouTubeStream) {
        self.videoInfo = videoInfo
        self.selectedStream = selectedStream
    }
    
    func onAppear() {
        setupPlayer()
        #if os(iOS)
        setupLifecycleObservers()
        #endif
        loadVideo()
    }
    
    func onDisappear() {
        loadGeneration += 1
        playerItemObserver?.invalidate()
        playerItemObserver = nil
        
        if let token = timeObserverToken {
            playbackManager.player.removeTimeObserver(token)
            timeObserverToken = nil
        }

        #if os(iOS)
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
        foregroundPreferredStream = nil
        isSwitchingForBackgroundPlayback = false
        isBackgroundPlaybackMode = false
        #endif

        pendingSeekTime = nil
        pendingResumeRate = nil
        
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
                Task { @MainActor in
                    self.updateNowPlaying(currentTime: time.seconds)
                }
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

    #if os(iOS)
    private func setupLifecycleObservers() {
        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.optimizeForBackgroundPlayback()
                }
            }
        }

        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.restoreForegroundPlaybackIfNeeded()
                }
            }
        }
    }

    private func optimizeForBackgroundPlayback() {
        guard
            !isSwitchingForBackgroundPlayback,
            !selectedStream.isAudioOnly,
            let audioStream = videoInfo.preferredAudioStream
        else {
            playbackManager.activateAudioSession()
            if playbackManager.player.timeControlStatus == .playing || playbackManager.player.rate > 0 {
                playbackManager.player.play()
            }
            return
        }

        foregroundPreferredStream = selectedStream
        let currentTime = playbackManager.player.currentTime().seconds
        pendingSeekTime = currentTime.isFinite && currentTime > 0 ? currentTime : nil
        pendingResumeRate = playbackManager.player.rate > 0 ? playbackManager.player.rate : 1.0
        isSwitchingForBackgroundPlayback = true
        isBackgroundPlaybackMode = true
        selectedStream = audioStream
    }

    private func restoreForegroundPlaybackIfNeeded() {
        guard
            isSwitchingForBackgroundPlayback,
            let preferredStream = foregroundPreferredStream
        else {
            return
        }

        let currentTime = playbackManager.player.currentTime().seconds
        pendingSeekTime = currentTime.isFinite && currentTime > 0 ? currentTime : pendingSeekTime
        pendingResumeRate = playbackManager.player.rate
        isSwitchingForBackgroundPlayback = false
        isBackgroundPlaybackMode = false
        foregroundPreferredStream = nil

        if preferredStream.id != selectedStream.id {
            selectedStream = preferredStream
        }
    }
    #endif
    
    func loadVideo() {
        loadGeneration += 1
        let generation = loadGeneration
        let stream = selectedStream
        let videoID = videoInfo.videoId
        isLoading = true
        errorMessage = nil
        sourceAssets.removeAll()
        
        Task {
            guard generation == self.loadGeneration else { return }

            if !playbackManager.shouldReload(videoID: videoID, streamID: stream.id) {
                if let seekTime = self.pendingSeekTime, seekTime.isFinite, seekTime > 0 {
                    let target = CMTime(seconds: seekTime, preferredTimescale: 600)
                    await playbackManager.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                guard generation == self.loadGeneration else { return }
                self.pendingSeekTime = nil
                let shouldResume = (self.pendingResumeRate ?? 1.0) > 0
                self.pendingResumeRate = nil
                if playbackManager.player.timeControlStatus != .playing {
                    playbackManager.activateAudioSession()
                    if shouldResume {
                        playbackManager.player.play()
                    }
                } else if shouldResume {
                    playbackManager.player.play()
                }
                updateNowPlaying()
                self.isLoading = false
                return
            }

            let videoURL: URL = stream.isVideoOnly ? stream.url : (stream.isAudioOnly ? (videoInfo.bestVideoStream?.url ?? stream.url) : stream.url)
            let audioURL: URL? = stream.isVideoOnly ? videoInfo.preferredAudioStream?.url : (stream.isAudioOnly ? stream.url : nil)
            print("▶️ Loading stream itag=\(stream.itag) quality=\(stream.quality) mime=\(stream.mimeType) audioOnly=\(stream.isAudioOnly) videoOnly=\(stream.isVideoOnly)")

            let playerItem: AVPlayerItem
            if stream.isAudioOnly {
                let asset = AVURLAsset(url: stream.url, options: makeAssetOptions(visitorData: videoInfo.visitorData))
                self.sourceAssets.append(asset)
                playerItem = AVPlayerItem(asset: asset)
            } else {
                playerItem = await createPlayerItem(videoURL: videoURL, audioURL: audioURL, visitorData: videoInfo.visitorData)
            }

            guard generation == self.loadGeneration, stream.id == self.selectedStream.id else { return }
            playbackManager.player.replaceCurrentItem(with: playerItem)
            self.observePlayerItem(playerItem, videoID: videoID, stream: stream, generation: generation)
            let seekTime = self.pendingSeekTime
            let shouldResume = (self.pendingResumeRate ?? 1.0) > 0
            self.pendingSeekTime = nil
            self.pendingResumeRate = nil
            self.playbackManager.activateAudioSession()
            if let seekTime, seekTime.isFinite, seekTime > 0 {
                let target = CMTime(seconds: seekTime, preferredTimescale: 600)
                await self.playbackManager.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if shouldResume {
                playbackManager.player.play()
            }
            updateNowPlaying()
            self.isLoading = false
        }
    }

    private func makeHTTPHeaders(visitorData: String?) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US; Pixel 8 Pro Build/UD1A.231105.004) gzip",
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/watch?v=\(videoInfo.videoId)",
            "X-YouTube-Client-Name": "3",
            "X-YouTube-Client-Version": "20.10.38"
        ]

        if let visitorData = visitorData {
            headers["X-Goog-Visitor-Id"] = visitorData
        }

        return headers
    }

    private func makeAssetOptions(visitorData: String?) -> [String: Any] {
        let headers = makeHTTPHeaders(visitorData: visitorData)
        var options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": headers
        ]
        if let userAgent = headers["User-Agent"] {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        return options
    }

    private func createPlayerItem(videoURL: URL, audioURL: URL?, visitorData: String?) async -> AVPlayerItem {
        let options = makeAssetOptions(visitorData: visitorData)

        let videoAsset = AVURLAsset(url: videoURL, options: options)
        self.sourceAssets.append(videoAsset)

        guard let audioURL = audioURL else {
            return AVPlayerItem(asset: videoAsset)
        }
        
        let audioAsset = AVURLAsset(url: audioURL, options: options)
        self.sourceAssets.append(audioAsset)
        
        let composition = AVMutableComposition()
        
        do {
            // Tải thông tin tracks và duration tuần tự để tránh gửi quá nhiều kết nối TCP đồng thời làm máy chủ YouTube từ chối (TCP Reset)
            let (vTracks, vDur) = try await videoAsset.load(.tracks, .duration)
            let (aTracks, aDur) = try await audioAsset.load(.tracks, .duration)

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
            self.sourceAssets.append(simpleVideoAsset)
            do {
                let (vTracks, _) = try await simpleVideoAsset.load(.tracks, .duration)
                if !vTracks.isEmpty {
                    return AVPlayerItem(asset: simpleVideoAsset)
                }
            } catch {
                print("Fallback không headers cũng thất bại: \(error.localizedDescription)")
            }
            
            let asset = AVURLAsset(url: videoURL, options: options)
            self.sourceAssets.append(asset)
            return AVPlayerItem(asset: asset)
        }
    }
    
    private func observePlayerItem(_ item: AVPlayerItem, videoID: String, stream: YouTubeStream, generation: Int) {
        playerItemObserver?.invalidate()
        playerItemObserver = item.observe(\.status, options: [.new, .old]) { [weak self] item, change in
            guard let self = self else { return }
            Task { @MainActor in
                guard generation == self.loadGeneration, item === self.playbackManager.player.currentItem else {
                    return
                }

                if item.status == .readyToPlay {
                    self.playbackManager.markLoaded(videoID: videoID, streamID: stream.id)
                    if !stream.isAudioOnly {
                        self.failedAudioStreamIDs.removeAll()
                    }
                } else if item.status == .failed {
                    print("⚠️ AVPlayerItem failed: \(String(describing: item.error?.localizedDescription))")
                    self.handlePlaybackFailure(error: item.error, failedStream: stream)
                }
            }
        }
    }
    
    private func handlePlaybackFailure(error: Error?, failedStream: YouTubeStream) {
        playbackManager.resetLoaded()

        if failedStream.isAudioOnly {
            failedAudioStreamIDs.insert(failedStream.id)
            if let fallbackStream = nextDirectAudioFallback(excluding: failedAudioStreamIDs) {
                print("🔁 Audio stream itag \(failedStream.itag) failed; retrying direct audio stream itag \(fallbackStream.itag)")
                let currentTime = playbackManager.player.currentTime().seconds
                pendingSeekTime = currentTime.isFinite && currentTime > 0 ? currentTime : pendingSeekTime
                pendingResumeRate = 1.0
                selectedStream = fallbackStream
                return
            }
        }

        let streamKind: String
        if failedStream.isAudioOnly {
            streamKind = "audio"
        } else if failedStream.isVideoOnly {
            streamKind = "video adaptive"
        } else {
            streamKind = "muxed"
        }

        self.errorMessage = "Không thể phát stream \(streamKind) itag \(failedStream.itag): \(error?.localizedDescription ?? "Lỗi kết nối từ YouTube CDN")"
    }

    private func nextDirectAudioFallback(excluding failedIDs: Set<String>) -> YouTubeStream? {
        let mp4Streams = videoInfo.audioStreams.filter {
            let mime = $0.mimeType.lowercased()
            return mime.contains("audio/mp4") || mime.contains("audio/m4a")
        }
        let candidates = (!mp4Streams.isEmpty ? mp4Streams : videoInfo.audioStreams)
            .filter { !failedIDs.contains($0.id) }

        let preferredItags = [139, 140, 141, 599]
        for itag in preferredItags {
            if let stream = candidates.first(where: { $0.itag == itag }) {
                return stream
            }
        }

        return candidates.sorted {
            let lhs = $0.bitrate ?? 0
            let rhs = $1.bitrate ?? 0
            if lhs == rhs {
                return ($0.audioSampleRate ?? "") > ($1.audioSampleRate ?? "")
            }
            return lhs > rhs
        }.first
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
            
            if let error = viewModel.errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(10)
                        .padding(.bottom, 20)
                }
                .transition(.slide)
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
                
                if let error = viewModel.errorMessage {
                    VStack {
                        Spacer()
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(8)
                            .padding(.bottom, 12)
                    }
                    .transition(.slide)
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
