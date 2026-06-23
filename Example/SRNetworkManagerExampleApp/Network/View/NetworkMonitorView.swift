import SRNetworkManager
import SwiftUI

struct NetworkMonitorView: View {
    @StateObject private var vm = NetworkMonitorViewModel()

    var body: some View {
        NavigationView {
            List {
                // Current status card
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: vm.connectivityIcon)
                            .font(.largeTitle)
                            .foregroundStyle(vm.statusColor)
                            .frame(width: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.connectivityLabel)
                                .font(.headline)
                            if case .connected = vm.connectivity {
                                Text(vm.isVPNActive ? "VPN tunnel active" : "No VPN")
                                    .font(.subheadline)
                                    .foregroundStyle(vm.isVPNActive ? .purple : .secondary)
                            }
                        }

                        Spacer()

                        Circle()
                            .fill(vm.statusColor)
                            .frame(width: 12, height: 12)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Current Status")
                }

                // VPN detail
                Section {
                    HStack {
                        Label("VPN Active", systemImage: "lock.shield")
                        Spacer()
                        Image(systemName: vm.isVPNActive ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(vm.isVPNActive ? .green : .secondary)
                    }

                    HStack {
                        Label("Detection method", systemImage: "info.circle")
                        Spacer()
                        Text("getifaddrs() + CFNetwork")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Refresh VPN check") { vm.refresh() }
                        .font(.subheadline)
                } header: {
                    Text("VPN Detection")
                } footer: {
                    Text("Checks for utun, tun, tap, ppp, ipsec interfaces via getifaddrs(). Works with IKEv2, WireGuard, OpenVPN, IPsec, and any tunnel-based VPN.")
                        .font(.caption)
                }

                // History
                if !vm.history.isEmpty {
                    Section {
                        ForEach(vm.history) { entry in
                            HStack {
                                Image(systemName: entryIcon(entry))
                                    .foregroundStyle(entryColor(entry))
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(entryLabel(entry))
                                            .font(.subheadline)
                                        if entry.vpn {
                                            Text("VPN")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.purple.opacity(0.15))
                                                .foregroundStyle(.purple)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(entry.timestamp, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("History (last 50)")
                    }
                }
            }
            .navigationTitle("Network Monitor")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: vm.refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private func entryLabel(_ e: NetworkMonitorViewModel.HistoryEntry) -> String {
        switch e.connectivity {
        case .disconnected:      return "Disconnected"
        case .connected(let t): return t.label
        }
    }

    private func entryIcon(_ e: NetworkMonitorViewModel.HistoryEntry) -> String {
        switch e.connectivity {
        case .disconnected:      return "wifi.slash"
        case .connected(let t): return t.icon
        }
    }

    private func entryColor(_ e: NetworkMonitorViewModel.HistoryEntry) -> Color {
        switch e.connectivity {
        case .disconnected: return .red
        case .connected(let t): return t == .vpn ? .purple : .green
        }
    }
}

// Needed because NetworkMonitorViewModel imports SwiftUI for Color
extension NetworkMonitorViewModel {
    typealias Color = SwiftUI.Color
}

#Preview {
    NetworkMonitorView()
}
