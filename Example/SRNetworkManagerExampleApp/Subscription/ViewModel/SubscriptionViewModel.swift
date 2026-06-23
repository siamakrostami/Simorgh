import Combine
import Foundation
import Simorgh

/// Demonstrates all three subscription APIs side-by-side:
/// 1. `apiClient.subscribe()` → AsyncThrowingStream  (async/await, fire-and-forget)
/// 2. `apiClient.subscribe()` → AnyPublisher          (Combine, fire-and-forget)
/// 3. `apiClient.subscription()` → SubscriptionConnection (explicit lifecycle)
@MainActor
final class SubscriptionViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case asyncStream = "Async Stream"
        case combine     = "Combine"
        case explicit    = "Explicit"
        var id: String { rawValue }
    }

    enum State: Equatable {
        case idle, connecting, live, failed(String)
        var label: String {
            switch self {
            case .idle:          return "Idle"
            case .connecting:    return "Connecting…"
            case .live:          return "Live"
            case .failed(let e): return "Error: \(e)"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var trades: [RealtimeTrade] = []
    @Published var symbol = "btcusdt"
    @Published var mode: Mode = .asyncStream

    private let apiClient = APIClient(logLevel: .standard)

    // Async stream handle
    private var streamTask: Task<Void, Never>?

    // Combine handle
    private var cancellable: AnyCancellable?

    // Explicit lifecycle handle
    private var explicitSub: SubscriptionConnection<BinanceSubscription>?

    deinit {
        streamTask?.cancel()
        cancellable = nil
        // explicitSub.disconnect() is async; best-effort fire-and-forget from deinit
        let sub = explicitSub
        Task.detached { await sub?.disconnect() }
    }

    // MARK: - Start

    func start() {
        stopAll()
        state = .connecting
        trades.removeAll()

        switch mode {
        case .asyncStream: startAsyncStream()
        case .combine:     startCombine()
        case .explicit:    startExplicit()
        }
    }

    func stop() {
        stopAll()
        state = .idle
    }

    // MARK: - Async Stream (fire-and-forget)

    private func startAsyncStream() {
        let options = makeOptions()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await trade in apiClient.subscribe(
                    BinanceSubscription(symbol: symbol),
                    options: options
                ) {
                    self.append(trade)
                }
                self.state = .idle
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
        state = .live
    }

    // MARK: - Combine (fire-and-forget)

    private func startCombine() {
        let options = makeOptions()
        cancellable = apiClient
            .subscribe(BinanceSubscription(symbol: symbol), options: options)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.state = .failed(error.localizedDescription)
                    } else {
                        self?.state = .idle
                    }
                },
                receiveValue: { [weak self] trade in
                    self?.append(trade)
                }
            )
        state = .live
    }

    // MARK: - Explicit lifecycle

    private func startExplicit() {
        do {
            let sub = try apiClient.subscription(
                BinanceSubscription(symbol: symbol),
                options: makeOptions()
            )
            explicitSub = sub

            // Set up stream BEFORE connecting so no events are missed
            streamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await trade in sub.events() {
                        self.append(trade)
                    }
                    self.state = .idle
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
            }

            sub.connect()
            state = .live
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    private func makeOptions() -> WebSocketOptions {
        WebSocketOptions(
            pingInterval: 25,
            reconnectPolicy: WebSocketReconnectPolicy(maximumAttempts: 3)
        )
    }

    private func stopAll() {
        streamTask?.cancel()
        streamTask = nil
        cancellable = nil
        Task { [explicitSub] in await explicitSub?.disconnect() }
        explicitSub = nil
    }

    private func append(_ trade: RealtimeTrade) {
        trades.insert(trade, at: 0)
        if trades.count > 30 { trades.removeLast() }
    }
}
