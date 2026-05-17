import SwiftUI
import Combine
import AVKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Video Service ViewModel (MVVM)
@MainActor
public class VideoServiceViewModel: ObservableObject {
    @Published public var searchQuery = ""
    @Published public var searchResults: [YouTubeVideo] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String? = nil
    
    // macOS Split-view selection state
    @Published public var selectedVideoID: String?
    @Published public var currentVideoInfo: YouTubeVideoInfo?
    @Published public var selectedStream: YouTubeStream?
    
    // Auth and sheet state
    @Published public var showLogin = false
    public let authManager = YouTubeAuthManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        // Automatically reload videos when login state changes (premium touch)
        authManager.$isLoggedIn
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.loadVideos()
            }
            .store(in: &cancellables)
    }
    
    public func loadVideos() {
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
                
                self.searchResults = results
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    public func selectVideo(_ video: YouTubeVideo) {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let extractor = YouTubeStreamExtractor(cookies: authManager.cookies)
                let info = try await extractor.extract(videoIDOrURL: video.id)
                self.currentVideoInfo = info
                self.selectedStream = info.bestMuxedStream ?? info.bestVideoStream
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

// MARK: - Video Service Router View
struct VideoServiceView: View {
    @StateObject private var viewModel = VideoServiceViewModel()
    
    var body: some View {
        #if os(macOS)
        MacVideoServiceView(viewModel: viewModel)
        #else
        iOSVideoServiceView(viewModel: viewModel)
        #endif
    }
}

// MARK: - macOS Platform Video Service View
#if os(macOS)
struct MacVideoServiceView: View {
    @ObservedObject var viewModel: VideoServiceViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("YouTube Lite")
        } detail: {
            if let videoID = viewModel.selectedVideoID, let stream = viewModel.selectedStream, let videoInfo = viewModel.currentVideoInfo {
                VideoPlayerView(
                    videoInfo: videoInfo,
                    selectedStream: Binding(
                        get: { stream },
                        set: { viewModel.selectedStream = $0 }
                    )
                )
                .id(videoID)
            } else {
                ContentUnavailableView(
                    "No Video Selected",
                    systemImage: "play.rectangle",
                    description: Text("Select a video from the sidebar to start playing")
                )
                .navigationTitle("YouTube Lite")
            }
        }
        .sheet(isPresented: $viewModel.showLogin) {
            YouTubeLoginView()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                profileMenu
            }
        }
    }
    
    private var sidebar: some View {
        VStack(spacing: 0) {
            // Native styled search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search YouTube...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { viewModel.loadVideos() }
                if !viewModel.searchQuery.isEmpty {
                    Button(action: {
                        viewModel.searchQuery = ""
                        viewModel.loadVideos()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding()
            
            if viewModel.isLoading && viewModel.searchResults.isEmpty {
                ProgressView()
                    .padding()
                Spacer()
            } else {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.callout)
                        .padding()
                }
                
                List(viewModel.searchResults, selection: $viewModel.selectedVideoID) { video in
                    NavigationLink(value: video.id) {
                        MacVideoRow(video: video)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: viewModel.selectedVideoID) { _, newID in
                    if let newID = newID, let video = viewModel.searchResults.first(where: { $0.id == newID }) {
                        viewModel.selectVideo(video)
                    }
                }
            }
        }
    }
    
    private var profileMenu: some View {
        Group {
            if viewModel.authManager.isLoggedIn {
                Menu {
                    Button(role: .destructive, action: { viewModel.authManager.logout() }) {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let avatarUrl = viewModel.authManager.avatarUrl {
                            AsyncImage(url: avatarUrl) { image in
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                            }
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        if let displayName = viewModel.authManager.displayName {
                            Text(displayName)
                                .font(.subheadline)
                        }
                    }
                }
            } else {
                Button(action: { viewModel.showLogin = true }) {
                    Label("Login", systemImage: "person.circle")
                }
            }
        }
    }
}

struct MacVideoRow: View {
    let video: YouTubeVideo
    @State private var isHovering = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AsyncImage(url: video.thumbnailUrl) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(width: 90, height: 50)
            .cornerRadius(4)
            .clipped()
            
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)
                
                if let channel = video.channelName {
                    Text(channel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 6) {
                    if let duration = video.duration {
                        Text(duration)
                    }
                    if video.duration != nil && video.viewCount != nil {
                        Text("•")
                    }
                    if let views = video.viewCount {
                        Text(views)
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.01 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
#endif

// MARK: - iOS Platform Video Service View (NavigationStack Optimized)
#if os(iOS)
struct iOSVideoServiceView: View {
    @ObservedObject var viewModel: VideoServiceViewModel
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom Premium Search Header
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search YouTube...", text: $viewModel.searchQuery)
                            .onSubmit { viewModel.loadVideos() }
                        if !viewModel.searchQuery.isEmpty {
                            Button(action: {
                                viewModel.searchQuery = ""
                                viewModel.loadVideos()
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    
                    profileButton
                }
                .padding()
                .background(Color(.systemBackground))
                
                // Video Grid / List
                if viewModel.isLoading && viewModel.searchResults.isEmpty {
                    Spacer()
                    ProgressView("Fetching videos...")
                    Spacer()
                } else if let error = viewModel.errorMessage {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") {
                            viewModel.loadVideos()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(viewModel.searchResults) { video in
                                NavigationLink(value: video) {
                                    iOSVideoCard(video: video)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        viewModel.loadVideos()
                    }
                }
            }
            .navigationTitle("Home Feed")
            .navigationBarHidden(true)
            .navigationDestination(for: YouTubeVideo.self) { video in
                iOSVideoDetailView(video: video)
            }
            .sheet(isPresented: $viewModel.showLogin) {
                YouTubeLoginView()
            }
        }
        .onAppear {
            if viewModel.searchResults.isEmpty {
                viewModel.loadVideos()
            }
        }
    }
    
    private var profileButton: some View {
        Button(action: {
            if viewModel.authManager.isLoggedIn {
                // Show simple sign out action sheet
                let alert = UIAlertController(title: "Account", message: viewModel.authManager.displayName, preferredStyle: .actionSheet)
                alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive, handler: { _ in
                    viewModel.authManager.logout()
                }))
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                    rootVC.present(alert, animated: true, completion: nil)
                }
            } else {
                viewModel.showLogin = true
            }
        }) {
            if viewModel.authManager.isLoggedIn, let avatarUrl = viewModel.authManager.avatarUrl {
                AsyncImage(url: avatarUrl) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                }
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .shadow(radius: 2)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .foregroundColor(.accentColor)
            }
        }
    }
}

// MARK: - Premium iOS Video Card View
struct iOSVideoCard: View {
    let video: YouTubeVideo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: video.thumbnailUrl) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .aspectRatio(16/9, contentMode: .fit)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16/9, contentMode: .fit)
                .cornerRadius(12)
                .clipped()
                
                // Duration pill overlay
                if let duration = video.duration {
                    Text(duration)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(6)
                        .padding(8)
                }
            }
            .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
            
            HStack(alignment: .top, spacing: 10) {
                // Dummy channel icon placeholder
                Circle()
                    .fill(LinearGradient(gradient: Gradient(colors: [.red, .orange]), startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(video.channelName?.first ?? "?").uppercased())
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    )
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: 6) {
                        if let channel = video.channelName {
                            Text(channel)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                        
                        if video.viewCount != nil {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(video.viewCount!)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
    }
}

// MARK: - iOS Video Detail ViewModel
@MainActor
class iOSVideoDetailViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var errorMessage: String? = nil
    @Published var videoInfo: YouTubeVideoInfo? = nil
    @Published var selectedStream: YouTubeStream? = nil
    
    func loadVideo(id: String) {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let extractor = YouTubeStreamExtractor(cookies: YouTubeAuthManager.shared.cookies)
                let info = try await extractor.extract(videoIDOrURL: id)
                self.videoInfo = info
                self.selectedStream = info.bestMuxedStream ?? info.bestVideoStream
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

// MARK: - iOS Video Detail Loader Page
struct iOSVideoDetailView: View {
    let video: YouTubeVideo
    @StateObject private var viewModel = iOSVideoDetailViewModel()
    
    var body: some View {
        Group {
            if viewModel.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Resolving streaming addresses...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text(error)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") {
                        viewModel.loadVideo(id: video.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            } else if let videoInfo = viewModel.videoInfo, let selectedStream = viewModel.selectedStream {
                VideoPlayerView(
                    videoInfo: videoInfo,
                    selectedStream: Binding(
                        get: { selectedStream },
                        set: { viewModel.selectedStream = $0 }
                    )
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.loadVideo(id: video.id)
        }
    }
}
#endif
