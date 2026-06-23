import Foundation
import SRNetworkManager

@MainActor
final class RealtimeSubscriptionViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int, delay: TimeInterval)
        case disconnected
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "Idle"
            case .connecting: return "Connecting…"
            case .connected: return "Live"
            case .reconnecting(let attempt, let delay): return "Reconnecting \(attempt) in \(Int(delay))s"
            case .disconnected: return "Disconnected"
            case .failed(let message): return "Failed: \(message)"
            }
        }

        var isActive: Bool {
            switch self {
            case .connected, .reconnecting: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var trades: [RealtimeTrade] = []
    @Published private(set) var acknowledgementID: Int?
    @Published var symbol = "btcusdt"

    private let apiClient = APIClient(logLevel: .standard)
    private var connection: WebSocketConnection?
    private var eventTask: Task<Void, Never>?

    deinit {
        eventTask?.cancel()
        connection?.close()
    }

    func connect() {
        disconnect()
        state = .connecting
        acknowledgementID = nil
        trades.removeAll()

        do {
            let connection = try apiClient.webSocketConnection(
                BinanceTradeSocket(),
                options: WebSocketOptions(
                    maximumMessageSize: 64 * 1024,
                    pingInterval: 25,
                    reconnectPolicy: WebSocketReconnectPolicy(
                        maximumAttempts: 3,
                        initialDelay: 1,
                        multiplier: 2,
                        maximumDelay: 30
                    )
                )
            )

            self.connection = connection
            let eventStream = connection.events(bufferingPolicy: .bufferingNewest(100))
            let subscribedSymbol = symbol.lowercased()

            eventTask = Task { [weak self] in
                do {
                    for try await event in eventStream {
                        await self?.handle(event, symbol: subscribedSymbol)
                    }
                } catch {
                    await self?.handleFailure(error)
                }
            }

            connection.connect()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        connection?.close()
        connection = nil
        state = .disconnected
    }

    // MARK: - Private

    private func handle(_ event: WebSocketEvent, symbol: String) async {
        switch event {
        case .connected:
            state = .connected
            await subscribe(to: symbol)
        case .message(let message):
            handleMessage(message)
        case .pong:
            break
        case .reconnecting(let attempt, let delay):
            state = .reconnecting(attempt: attempt, delay: delay)
        case .disconnected:
            if case .connected = state { state = .disconnected }
        }
    }

    private func subscribe(to symbol: String) async {
        let request = RealtimeSubscriptionRequest(
            method: "SUBSCRIBE",
            params: ["\(symbol)@trade"],
            id: 1
        )
        do {
            // send(_:) encodes value as JSON and sends it as a UTF-8 text frame
            try await connection?.send(request)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func handleMessage(_ message: WebSocketMessage) {
        let decoder = JSONDecoder()

        if let trade = try? message.decoded(as: RealtimeTrade.self, decoder: decoder) {
            trades.insert(trade, at: 0)
            if trades.count > 30 {
                trades.removeLast(trades.count - 30)
            }
            return
        }

        if let ack = try? message.decoded(as: RealtimeSubscriptionAcknowledgement.self, decoder: decoder) {
            acknowledgementID = ack.id
        }
    }

    private func handleFailure(_ error: Error) {
        if let networkError = error as? NetworkError {
            state = .failed(networkError.localizedDescription)
        } else {
            state = .failed(error.localizedDescription)
        }
    }
}
