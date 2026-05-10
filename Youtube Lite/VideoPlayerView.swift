import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let url: URL
    let title: String
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VideoPlayer(player: AVPlayer(url: url))
                .navigationTitle(title)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
#if os(iOS)
        .navigationViewStyle(.stack)
#endif
    }
}

#Preview {
    VideoPlayerView(
        url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
        title: "Preview Video"
    )
}
