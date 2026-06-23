import Combine
import Foundation
import SRNetworkManager

@MainActor
final class NetworkMonitorViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var connectivity: Connectivity = .disconnected
    @Published private(set) var isVPNActive: Bool = false
    @Published private(set) var history: [HistoryEntry] = []

    struct HistoryEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let connectivity: Connectivity
        let vpn: Bool
    }

    // MARK: - Init

    private let monitor = NetworkMonitor(shouldDetectVpnAutomatically: true)
    private let vpnChecker = VPNChecker()
    private var cancellables = Set<AnyCancellable>()

    init() {
        monitor.startMonitoring()

        monitor.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conn in
                guard let self else { return }
                let vpn = vpnChecker.isVPNActive()
                connectivity = conn
                isVPNActive = vpn
                history.insert(
                    HistoryEntry(timestamp: Date(), connectivity: conn, vpn: vpn),
                    at: 0
                )
                if history.count > 50 { history.removeLast() }
            }
            .store(in: &cancellables)
    }

    deinit {
        monitor.stopMonitoring()
    }

    func refresh() {
        isVPNActive = vpnChecker.isVPNActive()
    }

    // MARK: - Helpers

    var connectivityLabel: String {
        switch connectivity {
        case .disconnected: return "Disconnected"
        case .connected(let t): return t.label
        }
    }

    var connectivityIcon: String {
        switch connectivity {
        case .disconnected: return "wifi.slash"
        case .connected(let t): return t.icon
        }
    }

    var statusColor: Color {
        switch connectivity {
        case .disconnected: return .red
        case .connected(let t): return t == .vpn ? .purple : .green
        }
    }
}

// MARK: - NetworkType display helpers

import SwiftUI

extension NetworkType {
    var label: String {
        switch self {
        case .wifi:     return "Wi-Fi"
        case .cellular: return "Cellular"
        case .ethernet: return "Ethernet"
        case .vpn:      return "VPN"
        case .other:    return "Other"
        }
    }

    var icon: String {
        switch self {
        case .wifi:     return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .ethernet: return "cable.connector"
        case .vpn:      return "lock.shield"
        case .other:    return "network"
        }
    }
}
