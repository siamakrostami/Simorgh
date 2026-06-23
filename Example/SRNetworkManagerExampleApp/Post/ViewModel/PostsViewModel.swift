//
//  PostsViewModel.swift
//  SRGenericNetworkLayerSampleApp
//
//  Created by Siamak Rostami on 9/20/24.
//


// MARK: - PostsViewModel.swift

import Foundation
import Combine
import Simorgh

@MainActor
final class PostsViewModel: ObservableObject, Sendable {
    @Published private(set) var posts: [Post] = []
    @Published var showError = false
    @Published var errorMessage = ""
    
    private var cancellables = Set<AnyCancellable>()
    private let apiClient = APIClient(logLevel: .verbose)
    
    //MARK: - Combine API Call
//    func fetchPosts() {
//        apiClient.request(PostsAPI())
//            .receive(on: DispatchQueue.main)
//            .sink { [weak self] completion in
//                switch completion {
//                case .finished:
//                    break
//                case .failure(let error):
//                    self?.showError = true
//                    self?.errorMessage = error.localizedErrorDescription ?? ""
//                }
//            } receiveValue: { [weak self] (posts: [Post]) in
//                self?.posts = posts
//            }
//            .store(in: &cancellables)
//    }
    
    //MARK: - Async API Call
    func fetchPosts(){
        Task{
            do{
                let response: [Post] = try await apiClient.request(PostsAPI())
                self.posts = response
            }catch let error as NetworkError{
                self.showError = true
                self.errorMessage = error.localizedErrorDescription ?? ""
            }
        }
    }
}
