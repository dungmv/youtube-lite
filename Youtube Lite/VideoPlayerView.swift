import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let url: URL
    let title: String

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
            } else {
                ProgressView("Loading video...")
            }
        }
#if os(macOS)
        .frame(minWidth: 640, idealWidth: 960, minHeight: 360, idealHeight: 540)
#endif
        .onAppear {
            let player = AVPlayer(url: url)
            player.play()
            self.player = player
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

#Preview {
    VideoPlayerView(
        url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
        title: "Preview Video"
    )
}
