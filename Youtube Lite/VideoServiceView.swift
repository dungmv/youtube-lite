import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import AVKit

struct VideoServiceView: View {
    @State private var videoID = "dQw4w9WgXcQ"
    @State private var streams: [VideoStreamInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedStream: VideoStreamInfo?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                inputBar
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
                if isLoading {
                    ProgressView("Fetching video links…")
                        .padding()
                }
                streamList
            }
            .navigationTitle("YouTube Link Extractor")
            .onAppear { fetchLinks() }
            .sheet(item: $selectedStream) { stream in
                if let url = stream.directURL {
                    VideoPlayerView(url: url, title: stream.quality)
                } else {
                    EmptyView()
                }
            }
        }
    }
    
    private var inputBar: some View {
        HStack {
            TextField("Video ID", text: $videoID)
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
    
    private var streamList: some View {
        List(streams) { stream in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("itag \(stream.itag)").bold()
                    Text(stream.quality).foregroundColor(.secondary)
                    if stream.isAdaptive {
                        Text("adaptive").font(.caption2).padding(2).background(Color.yellow.opacity(0.3)).cornerRadius(4)
                    }
                }
                if let mime = stream.mimeType {
                    Text(mime).font(.caption)
                }
                if let url = stream.directURL {
                    Text(url.absoluteString)
                        .font(.caption2)
                        .lineLimit(2)
                        .contextMenu {
                            Button("Copy URL") {
    #if os(iOS)
                                UIPasteboard.general.string = url.absoluteString
    #elseif os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
    #endif
                            }
                        }
                } else {
                    Text("❌ No direct URL").foregroundColor(.red).font(.caption)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                if stream.directURL != nil {
                    selectedStream = stream
                }
            }
        }
        .listStyle(.plain)
    }
    
    private func fetchLinks() {
        let trimmed = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        videoID = trimmed
        isLoading = true
        errorMessage = nil
        streams = []
        YouTubeService.shared.fetchVideoStreams(videoID: trimmed) { result in
            DispatchQueue.main.async { [self] in
                isLoading = false
                switch result {
                case .success(let list):
                    streams = list
                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
        }
    }
}

#Preview {
    VideoServiceView()
}
