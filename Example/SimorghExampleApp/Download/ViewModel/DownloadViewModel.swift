import Combine
import Foundation
import Simorgh

// MARK: - Demo catalog

struct DemoFile: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let type: String
}

let downloadCatalog: [DemoFile] = [
    // PDF
    DemoFile(name: "PDF — Sample (4 KB)",    url: "https://www.africau.edu/images/default/sample.pdf",       type: "PDF"),
    DemoFile(name: "PDF — W3C (168 KB)",     url: "https://www.w3.org/WAI/WCAG21/Techniques/pdf/pdf-sample.pdf", type: "PDF"),
    // Video
    DemoFile(name: "MP4 — For Bigger Blazes (~5 MB)",  url: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",           type: "MP4"),
    DemoFile(name: "MP4 — Subaru Outback (~11 MB)",    url: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackOnStreetAndDirt.mp4", type: "MP4"),
    // Audio
    DemoFile(name: "MP3 — SoundHelix #1 (~9 MB)", url: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3", type: "MP3"),
    DemoFile(name: "MP3 — SoundHelix #2 (~7 MB)", url: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3", type: "MP3"),
    DemoFile(name: "WAV — On the Trail (8 MB)",   url: "https://upload.wikimedia.org/wikipedia/commons/2/21/On_the_Trail.wav", type: "WAV"),
    // Images
    DemoFile(name: "JPEG — Cat photo (450 KB)", url: "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Cat_November_2010-1a.jpg/1200px-Cat_November_2010-1a.jpg", type: "JPEG"),
    DemoFile(name: "PNG — Transparency (1.2 MB)", url: "https://upload.wikimedia.org/wikipedia/commons/4/47/PNG_transparency_demonstration_1.png", type: "PNG"),
    DemoFile(name: "GIF — Rotating Earth (3 MB)", url: "https://upload.wikimedia.org/wikipedia/commons/2/2c/Rotating_earth_%28large%29.gif", type: "GIF"),
    // Archive
    DemoFile(name: "ZIP — Alamofire source (~600 KB)", url: "https://codeload.github.com/Alamofire/Alamofire/zip/refs/tags/5.8.1", type: "ZIP"),
]

// MARK: - ViewModel

@MainActor
final class DownloadViewModel: ObservableObject {

    // MARK: - Row

    struct Row: Identifiable {
        let id: UUID
        let url: URL
        var fileName: String
        var state: DownloadState
        var fraction: Double
        var speedKBps: Double
        var etaSeconds: TimeInterval?
        var localURL: URL?
        var fileSizeBytes: Int64 = 0
        var errorMessage: String?

        var fileSizeString: String {
            guard fileSizeBytes > 0 else { return "" }
            return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
        }

        var speedString: String {
            let bps = speedKBps * 1024
            switch bps {
            case ..<1024:
                return String(format: "%.0f B/s", bps)
            case ..<(1024 * 1024):
                return String(format: "%.1f KB/s", bps / 1024)
            case ..<(1024 * 1024 * 1024):
                return String(format: "%.2f MB/s", bps / (1024 * 1024))
            default:
                return String(format: "%.2f GB/s", bps / (1024 * 1024 * 1024))
            }
        }
    }

    // MARK: - Published

    @Published private(set) var rows: [Row] = []
    @Published var urlText = ""
    @Published var selectedPriority: DownloadPriority = .normal

    // Batch catalog selection
    @Published var selectedDemoIDs: Set<UUID> = []

    // MARK: - Init

    private let manager: DownloadManager
    private var cancellables = Set<AnyCancellable>()

    init() {
        manager = (try? DownloadManager(config: DownloadManagerConfig(
            maxConcurrentDownloads: 3,
            retryPolicy: DownloadRetryPolicy(maximumAttempts: 2)
        ), logLevel: .standard)) ?? (try! DownloadManager())

        manager.eventsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    // MARK: - Single enqueue

    func enqueue(urlString: String? = nil, priority: DownloadPriority? = nil) {
        let raw = urlString ?? urlText
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return }
        let p = priority ?? selectedPriority
        do {
            let id = try manager.enqueue(url: url, priority: p)
            rows.append(Row(
                id: id, url: url,
                fileName: url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent,
                state: .queued, fraction: 0, speedKBps: 0
            ))
            if urlString == nil { urlText = "" }
        } catch DownloadError.alreadyQueued { }
        catch { }
    }

    // MARK: - Batch enqueue

    func toggleDemoSelection(_ id: UUID) {
        if selectedDemoIDs.contains(id) { selectedDemoIDs.remove(id) }
        else { selectedDemoIDs.insert(id) }
    }

    func selectAllDemos() {
        selectedDemoIDs = Set(downloadCatalog.map(\.id))
    }

    func clearDemoSelection() {
        selectedDemoIDs = []
    }

    func downloadSelected() {
        let items = downloadCatalog.filter { selectedDemoIDs.contains($0.id) }
        let urls = items.compactMap { URL(string: $0.url) }
        manager.enqueueBatch(urls, priority: selectedPriority)
        // Rows added via .added events from eventsPublisher
        selectedDemoIDs = []
    }

    // MARK: - Controls

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
            let localURL = manager.tasks.first { $0.id == id }?.localURL
            rows[idx].localURL = localURL
            if let path = localURL?.path,
               let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                rows[idx].fileSizeBytes = size
            }
        }
    }
}
