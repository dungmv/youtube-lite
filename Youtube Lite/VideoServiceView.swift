import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import AVKit

struct VideoServiceView: View {
    @State private var videoID = "k8m0SaGQ_1c"
    @State private var videoInfo: YouTubeVideoInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedStream: YouTubeStream?

    private let extractor = YouTubeStreamExtractor()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("YouTube Link Extractor")
        } detail: {
            if let stream = selectedStream {
                let videoURL: URL = stream.isVideoOnly ? stream.url : (stream.isAudioOnly ? (videoInfo?.bestVideoStream?.url ?? stream.url) : stream.url)
                let audioURL: URL? = stream.isVideoOnly ? videoInfo?.bestAudioStream?.url : (stream.isAudioOnly ? stream.url : nil)
                
                VideoPlayerView(videoURL: videoURL, audioURL: audioURL, visitorData: videoInfo?.visitorData, title: stream.quality)
                    .id(stream.id)
            } else {
                ContentUnavailableView("No Video Selected",
                    systemImage: "play.rectangle",
                    description: Text("Select a stream from the sidebar to play"))
                    .navigationTitle("YouTube Lite")
            }
        }
        .onAppear { fetchLinks() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            inputBar
            if let title = videoInfo?.title {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
            if isLoading {
                ProgressView("Fetching video links…")
                    .padding()
            }
            List(selection: $selectedStream) {
                ForEach(allStreams) { stream in
                    streamRow(stream)
                        .tag(stream)
                }
            }
            .listStyle(.plain)
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Video ID or URL", text: $videoID)
                .textFieldStyle(.roundedBorder)
#if os(iOS)
                .autocapitalization(.none)
                .disableAutocorrection(true)
#endif
            Button("Fetch") { fetchLinks() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
                .disabled(isLoading)
        }
        .padding()
    }

    /// Tổng hợp tất cả stream: muxed trước (dễ play nhất), sau đó video-only, cuối cùng audio-only
    private var allStreams: [YouTubeStream] {
        guard let info = videoInfo else { return [] }
        return info.muxedStreams + info.videoStreams + info.audioStreams
    }

    private func streamRow(_ stream: YouTubeStream) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("itag \(stream.itag)").bold()
                Text(stream.quality).foregroundColor(.secondary)
                streamTypeBadge(stream)
            }
            Text(stream.mimeType).font(.caption)
            Text(stream.url.absoluteString)
                .font(.caption2)
                .lineLimit(2)
                .contextMenu {
                    Button("Copy URL") {
#if os(iOS)
                        UIPasteboard.general.string = stream.url.absoluteString
#elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(stream.url.absoluteString, forType: .string)
#endif
                    }
                }
            if let width = stream.width, let height = stream.height {
                Text("\(width)×\(height)").font(.caption2).foregroundColor(.secondary)
            }
            if let bitrate = stream.bitrate {
                Text("\(bitrate / 1000) kbps").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func streamTypeBadge(_ stream: YouTubeStream) -> some View {
        if stream.isVideoOnly {
            Text("Video only")
                .font(.caption2)
                .padding(2)
                .background(Color.blue.opacity(0.15))
                .cornerRadius(4)
        } else if stream.isAudioOnly {
            Text("Audio only")
                .font(.caption2)
                .padding(2)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)
        } else {
            Text("Muxed")
                .font(.caption2)
                .padding(2)
                .background(Color.yellow.opacity(0.3))
                .cornerRadius(4)
        }
    }

    private func fetchLinks() {
        let trimmed = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        videoID = trimmed
        isLoading = true
        errorMessage = nil
        videoInfo = nil

        Task {
            do {
                let info = try await extractor.extract(videoIDOrURL: trimmed)
                await MainActor.run {
                    self.videoInfo = info
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

#Preview {
    VideoServiceView()
}
