import SRNetworkManager
import SwiftUI

struct DownloadView: View {
    @StateObject private var vm = DownloadViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // URL input
                VStack(spacing: 8) {
                    HStack {
                        TextField("https://...", text: $vm.urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)

                        Button("Add") { vm.enqueue() }
                            .buttonStyle(.borderedProminent)
                            .disabled(vm.urlText.isEmpty)
                    }

                    Picker("Priority", selection: $vm.selectedPriority) {
                        Text("Low").tag(DownloadPriority.low)
                        Text("Normal").tag(DownloadPriority.normal)
                        Text("High").tag(DownloadPriority.high)
                        Text("Critical").tag(DownloadPriority.critical)
                    }
                    .pickerStyle(.segmented)
                }
                .padding()

                Divider()

                // Demo shortcuts
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.demoURLs, id: \.url) { demo in
                            Button(demo.name) {
                                vm.enqueue(urlString: demo.url)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }

                Divider()

                // Downloads list
                if vm.rows.isEmpty {
                    Spacer()
                    Text("No downloads yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(vm.rows) { row in
                            DownloadRowView(row: row, vm: vm)
                        }
                    }
                    .listStyle(.plain)

                    if vm.rows.contains(where: { $0.state == .completed }) {
                        Button("Clear Completed", action: vm.removeCompleted)
                            .font(.footnote)
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

// MARK: - DownloadRowView

private struct DownloadRowView: View {
    let row: DownloadViewModel.Row
    let vm: DownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // File name + state badge
            HStack {
                Text(row.fileName.isEmpty ? row.url.lastPathComponent : row.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                stateBadge
            }

            // Progress bar
            if row.state == .downloading || row.state == .paused {
                ProgressView(value: row.fraction.isNaN ? 0 : row.fraction)
                    .progressViewStyle(.linear)
            }

            // Speed / ETA / error
            if row.state == .downloading {
                HStack {
                    Text(String(format: "%.1f KB/s", row.speedKBps))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let eta = row.etaSeconds {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("ETA \(Int(eta))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !row.fraction.isNaN {
                        Spacer()
                        Text(String(format: "%.0f%%", row.fraction * 100))
                            .font(.caption.monospacedDigit())
                    }
                }
            } else if let err = row.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if row.state == .completed, let url = row.localURL {
                Text(url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Action buttons
            HStack(spacing: 8) {
                Spacer()
                switch row.state {
                case .downloading:
                    Button("Pause") { vm.pause(id: row.id) }
                        .buttonStyle(.bordered)
                        .font(.caption)
                case .paused:
                    Button("Resume") { vm.resume(id: row.id) }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                case .failed:
                    Button("Retry") { vm.resume(id: row.id) }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                default:
                    EmptyView()
                }
                if row.state != .completed {
                    Button("Cancel") { vm.cancel(id: row.id) }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .tint(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let (label, color): (String, Color) = {
            switch row.state {
            case .queued:      return ("Queued", .orange)
            case .downloading: return ("↓", .blue)
            case .paused:      return ("Paused", .yellow)
            case .completed:   return ("Done", .green)
            case .failed:      return ("Failed", .red)
            case .cancelled:   return ("Cancelled", .gray)
            }
        }()
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

#Preview {
    DownloadView()
}
