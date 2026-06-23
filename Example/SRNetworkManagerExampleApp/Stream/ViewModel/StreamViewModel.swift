import Combine
import Foundation
import SRNetworkManager

@MainActor
final class StreamViewModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case combine = "Combine"
        case async   = "Async/Await"
        var id: String { rawValue }
    }

    enum State { case idle, streaming, done, failed(String) }

    @Published private(set) var chunks: [StreamChunk] = []
    @Published private(set) var state: State = .idle
    @Published var selectedMode: Mode = .async
    @Published var chunkCount: Double = 10

    private let client = APIClient(logLevel: .standard)
    private var cancellable: AnyCancellable?
    private var streamTask: Task<Void, Never>?

    func start() {
        chunks = []
        state = .streaming
        let router = StreamRouter(count: Int(chunkCount))

        switch selectedMode {
        case .combine:
            startCombine(router: router)
        case .async:
            startAsync(router: router)
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        streamTask?.cancel()
        streamTask = nil
        if case .streaming = state { state = .idle }
    }

    // MARK: - Combine

    private func startCombine(router: StreamRouter) {
        let publisher: AnyPublisher<StreamChunk, NetworkError> = client.streamRequest(router)
        cancellable = publisher
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    switch completion {
                    case .finished:         self.state = .done
                    case .failure(let e):   self.state = .failed(e.localizedDescription)
                    }
                },
                receiveValue: { [weak self] chunk in
                    self?.chunks.append(chunk)
                }
            )
    }

    // MARK: - Async/Await

    private func startAsync(router: StreamRouter) {
        streamTask = Task {
            do {
                let stream: AsyncThrowingStream<StreamChunk, Error> = client.asyncStreamRequest(router)
                for try await chunk in stream {
                    chunks.append(chunk)
                }
                state = .done
            } catch is CancellationError {
                // user stopped — leave state as-is
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
