import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import AVKit

struct VideoServiceView: View {
    @State private var searchQuery = ""
    @State private var searchResults: [YouTubeVideo] = []
    @State private var currentVideoInfo: YouTubeVideoInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedStream: YouTubeStream?
    @State private var showLogin = false
    @StateObject private var authManager = YouTubeAuthManager.shared
    @State private var selectedVideoID: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("YouTube")
        } detail: {
            if let videoID = selectedVideoID, let stream = selectedStream, let videoInfo = currentVideoInfo {
                VideoPlayerView(
                    videoInfo: videoInfo,
                    selectedStream: Binding(
                        get: { stream },
                        set: { selectedStream = $0 }
                    )
                )
                .id(videoID)
            } else {
                ContentUnavailableView("No Video Selected",
                    systemImage: "play.rectangle",
                    description: Text("Select a video from the sidebar to play"))
                    .navigationTitle("YouTube Lite")
            }
        }
        .onAppear { loadVideos() }
        .sheet(isPresented: $showLogin) {
            YouTubeLoginView()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if authManager.isLoggedIn {
                    profileMenu
                } else {
                    Button(action: { showLogin = true }) {
                        Label("Login", systemImage: "person.circle")
                    }
                }
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            Button(role: .destructive, action: { authManager.logout() }) {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            if let avatarUrl = authManager.avatarUrl {
                AsyncImage(url: avatarUrl) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: 28, height: 28)
                    .foregroundColor(.blue)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            inputBar
            if isLoading {
                ProgressView()
                    .padding()
            }
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            }
            List(searchResults, selection: $selectedVideoID) { video in
                NavigationLink(value: video.id) {
                    videoRow(video)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedVideoID) { oldID, newID in
                if let newID = newID, let video = searchResults.first(where: { $0.id == newID }) {
                    selectVideo(video)
                }
            }
        }
    }

    private func videoRow(_ video: YouTubeVideo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AsyncImage(url: video.thumbnailUrl) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.gray.opacity(0.3)
            }
            .frame(width: 80, height: 45)
            .cornerRadius(4)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                
                if let channel = video.channelName {
                    Text(channel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    if let duration = video.duration {
                        Text(duration)
                    }
                    if let views = video.viewCount {
                        Text("• \(views)")
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var inputBar: some View {
        HStack {
            TextField("Search YouTube...", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { loadVideos() }
            
            Button(action: { loadVideos() }) {
                Image(systemName: "magnifyingglass")
            }
            .disabled(isLoading)
        }
        .padding()
    }


    private func loadVideos() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let extractor = YouTubeStreamExtractor(cookies: authManager.cookies)
                let results: [YouTubeVideo]
                if query.isEmpty {
                    results = try await extractor.recommendations()
                } else {
                    results = try await extractor.search(query: query)
                }
                
                await MainActor.run {
                    self.searchResults = results
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

    private func selectVideo(_ video: YouTubeVideo) {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let extractor = YouTubeStreamExtractor(cookies: authManager.cookies)
                let info = try await extractor.extract(videoIDOrURL: video.id)
                await MainActor.run {
                    self.currentVideoInfo = info
                    // Mặc định chọn stream muxed tốt nhất hoặc video tốt nhất
                    self.selectedStream = info.bestMuxedStream ?? info.bestVideoStream
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

#Preview("Video Service") {
    VideoServiceView()
}
