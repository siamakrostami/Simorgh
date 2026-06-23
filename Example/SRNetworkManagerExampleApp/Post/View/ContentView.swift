// MARK: - ContentView.swift

import SwiftUI
import Combine
import SRNetworkManager

struct ContentView: View {
    @StateObject private var viewModel = PostsViewModel()

    var body: some View {
        TabView {
            // Posts tab
            NavigationView {
                List {
                    ForEach(viewModel.posts) { post in
                        VStack(alignment: .leading) {
                            Text(post.title)
                                .font(.headline)
                            Text(post.body)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("Posts")
                .onAppear {
                    Task { viewModel.fetchPosts() }
                }
                .alert(isPresented: $viewModel.showError) {
                    Alert(
                        title: Text("Error"),
                        message: Text(viewModel.errorMessage),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
            .tabItem { Label("Posts", systemImage: "doc.text") }

            // Downloads tab
            DownloadView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            // Upload tab
            ImageUploadView()
                .tabItem { Label("Upload", systemImage: "square.and.arrow.up") }

            // Network / VPN monitor tab
            NetworkMonitorView()
                .tabItem { Label("Network", systemImage: "network") }
        }
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0 , *)
#Preview("View") {
    return ContentView()
}
