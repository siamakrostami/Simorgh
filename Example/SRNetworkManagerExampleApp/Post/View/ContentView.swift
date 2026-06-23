// MARK: - ContentView.swift

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PostsViewModel()
    
    var body: some View {
        TabView {
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
                    Task {
                        viewModel.fetchPosts()
                    }
                }
                .alert(isPresented: $viewModel.showError) {
                    Alert(
                        title: Text("Error"),
                        message: Text(viewModel.errorMessage),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
            .tabItem {
                Label("Posts", systemImage: "doc.text")
            }

            RealtimeSubscriptionView()
                .tabItem {
                    Label("Realtime", systemImage: "dot.radiowaves.left.and.right")
                }

            ImageUploadView()
                .tabItem {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
            }
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0 , *)
#Preview("View") {
    return ContentView()
}
