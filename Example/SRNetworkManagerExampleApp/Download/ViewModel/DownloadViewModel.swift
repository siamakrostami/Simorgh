import Combine
import Foundation
import SRNetworkManager

@MainActor
final class DownloadViewModel: ObservableObject {

    // MARK: - State

    struct Row: Identifiable {
        let id: UUID
        let url: URL
        var fileName: String
        var state: DownloadState
        var fraction: Double        // 0..1, NaN = indeterminate
        var speedKBps: Double
        var etaSeconds: TimeInterval?
        var localURL: URL?
        var errorMessage: String?
    }

    @Published private(set) var rows: [Row] = []
    @Published var urlText = ""
    @Published var selectedPriority: DownloadPriority = .normal

    // Quick-access demo downloads
    let demoURLs: [(name: String, url: String)] = [
        ("Big Buck Bunny (5 MB)", "https://download.samplelib.com/mp4/sample-5s.mp4"),
        ("Sample PDF", "https://www.w3.org/WAI/WCAG21/Techniques/pdf/pdf-sample.pdf"),
        ("NASA Image (3 MB)", "https://apod.nasa.gov/apod/image/2406/M104_Hubble_2711.jpg"),
    ]

    private let manager: DownloadManager
    private var cancellables = Set<AnyCancellable>()

    init() {
        manager = (try? DownloadManager(config: DownloadManagerConfig(
            maxConcurrentDownloads: 3,
            retryPolicy: DownloadRetryPolicy(maximumAttempts: 3)
        ), logLevel: .standard)) ?? (try! DownloadManager())

        manager.eventsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func enqueue(urlString: String? = nil, priority: DownloadPriority? = nil) {
        let raw = urlString ?? urlText
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return }
        let p = priority ?? selectedPriority
        do {
            let id = try manager.enqueue(url: url, priority: p)
            rows.append(Row(
                id: id, url: url,
                fileName: url.lastPathComponent,
                state: .queued,
                fraction: 0, speedKBps: 0
            ))
            if urlString == nil { urlText = "" }
        } catch DownloadError.alreadyQueued {
            // already in list — ignore silently
        } catch {}
    }

    func pause(id: UUID) { manager.pause(id: id) }

    func resume(id: UUID) { try? manager.resume(id: id) }

    func cancel(id: UUID) {
        manager.cancel(id: id)
        rows.removeAll { $0.id == id }
    }

    func removeCompleted() {
        manager.removeCompleted()
        rows.removeAll { $0.state == .completed }
    }

    // MARK: - Event handler

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let p):
            updateRow(id: p.taskId) { row in
                row.state = p.state
                row.fraction = p.fraction
                row.speedKBps = p.speed / 1024
                row.etaSeconds = p.eta
            }
        case .stateChange(let id, let state):
            updateRow(id: id) { $0.state = state }
        case .error(let id, let msg):
            updateRow(id: id) { row in
                row.state = .failed
                row.errorMessage = msg
            }
        case .added(let task):
            if !rows.contains(where: { $0.id == task.id }) {
                rows.append(Row(
                    id: task.id, url: task.url,
                    fileName: task.fileName,
                    state: task.state,
                    fraction: 0, speedKBps: 0
                ))
            }
        case .removed(let id):
            rows.removeAll { $0.id == id }
        }
    }

    private func updateRow(id: UUID, _ mutation: (inout Row) -> Void) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        mutation(&rows[idx])
        if rows[idx].state == .completed {
            rows[idx].localURL = manager.tasks.first { $0.id == id }?.localURL
        }
    }
}
