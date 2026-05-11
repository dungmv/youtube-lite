import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let url: URL
    let title: String

    var body: some View {
        AVPlayerContainerView(url: url)
            .frame(minWidth: 640, idealWidth: 960, minHeight: 360, idealHeight: 540)
            .navigationTitle(title)
    }
}

struct AVPlayerContainerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.allowsVideoFrameAnalysis = true
        
        let player = AVPlayer(url: url)
        playerView.player = player
        
        // Tự động phát
        player.play()
        
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Cập nhật URL nếu cần (nhưng ở đây ta dùng .id() bên ngoài để reset view)
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

#Preview {
    VideoPlayerView(
        url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
        title: "Preview Video"
    )
}
