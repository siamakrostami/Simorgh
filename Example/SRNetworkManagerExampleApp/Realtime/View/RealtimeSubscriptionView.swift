import SwiftUI

struct RealtimeSubscriptionView: View {
    @StateObject private var viewModel = RealtimeSubscriptionViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    TextField("Symbol", text: $viewModel.symbol)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Button("Connect") {
                        viewModel.connect()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Stop") {
                        viewModel.disconnect()
                    }
                    .buttonStyle(.bordered)
                }

                HStack {
                    Text(viewModel.state.title)
                        .font(.headline)
                    Spacer()
                    if let acknowledgementID = viewModel.acknowledgementID {
                        Text("Ack \(acknowledgementID)")
                            .foregroundStyle(.secondary)
                    }
                }

                List(viewModel.trades) { trade in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trade.symbol)
                                .font(.headline)
                            Text("Qty \(trade.quantity)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(trade.price)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(trade.isBuyerMarketMaker ? .red : .green)
                    }
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("Realtime Trades")
        }
    }
}

#Preview {
    RealtimeSubscriptionView()
}
