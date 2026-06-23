import SwiftUI

struct SubscriptionView: View {
    @StateObject private var viewModel = SubscriptionViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {

                // Mode picker
                Picker("Mode", selection: $viewModel.mode) {
                    ForEach(SubscriptionViewModel.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Controls
                HStack(spacing: 8) {
                    TextField("Symbol", text: $viewModel.symbol)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Button("Start") { viewModel.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.state == .live || viewModel.state == .connecting)

                    Button("Stop") { viewModel.stop() }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.state == .idle)
                }
                .padding(.horizontal)

                // State
                HStack {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Text(viewModel.state.label)
                        .font(.subheadline)
                    Spacer()
                    Text(viewModel.mode.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // Trade list
                List(viewModel.trades) { trade in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trade.symbol).font(.headline)
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
            .navigationTitle("Subscription API")
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .live:       return .green
        case .connecting: return .orange
        case .failed:     return .red
        case .idle:       return .gray
        }
    }
}

#Preview {
    SubscriptionView()
}
