import Simorgh
import SwiftUI

struct StreamView: View {
    @StateObject private var vm = StreamViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Controls
                VStack(spacing: 10) {
                    Picker("Mode", selection: $vm.selectedMode) {
                        ForEach(StreamViewModel.Mode.allCases) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Chunks: \(Int(vm.chunkCount))")
                            .font(.subheadline)
                        Slider(value: $vm.chunkCount, in: 1...50, step: 1)
                    }

                    HStack(spacing: 12) {
                        Button(action: vm.start) {
                            Label("Start Stream", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isStreaming)

                        if isStreaming {
                            Button(action: vm.stop) {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                }
                .padding()

                Divider()

                // Status bar
                HStack {
                    statusIcon
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !vm.chunks.isEmpty {
                        Text("\(vm.chunks.count) chunks")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))

                // Chunk list
                if vm.chunks.isEmpty {
                    Spacer()
                    Text(isStreaming ? "Waiting for data…" : "Tap Start Stream to begin")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(vm.chunks.indices, id: \.self) { i in
                        let chunk = vm.chunks[i]
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("#\(chunk.id)")
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundStyle(.blue)
                                Spacer()
                                Text(chunk.origin)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(chunk.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("HTTP Streaming")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !vm.chunks.isEmpty {
                        Button("Clear") { vm.stop(); }
                    }
                }
            }
        }
    }

    private var isStreaming: Bool {
        if case .streaming = vm.state { return true }
        return false
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch vm.state {
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .streaming:
            ProgressView().scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch vm.state {
        case .idle:             return "Idle"
        case .streaming:        return "Streaming via \(vm.selectedMode.rawValue)…"
        case .done:             return "Stream complete"
        case .failed(let msg):  return "Error: \(msg)"
        }
    }
}

#Preview {
    StreamView()
}
