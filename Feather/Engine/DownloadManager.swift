import AppKit
import WebKit

/// Saves downloads to ~/Downloads and reports progress to the sidebar and its
/// downloads popover.
@Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    struct Item: Identifiable {
        let id = UUID()
        var filename: String
        var destination: URL?
        var progress = 0.0
        var finished = false
        var failed = false
        var cancelled = false
        var isActive: Bool { !finished && !failed }
    }

    private(set) var items: [Item] = []
    /// Called on the main thread when a download completes.
    @ObservationIgnored var onFinish: ((Item) -> Void)?
    @ObservationIgnored private var ids: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var running: [UUID: WKDownload] = [:]
    @ObservationIgnored private var observations: [UUID: NSKeyValueObservation] = [:]

    var active: Item? { items.last { $0.isActive } }

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = Item(filename: download.originalRequest?.url?.lastPathComponent ?? "Download")
        items.append(item)
        ids[ObjectIdentifier(download)] = item.id
        running[item.id] = download
        observations[item.id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async { self?.updateItem(item.id) { $0.progress = fraction } }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Self.uniqueURL(in: folder, for: suggestedFilename)
        update(download) {
            $0.filename = destination.lastPathComponent
            $0.destination = destination
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        update(download) {
            $0.finished = true
            $0.progress = 1
        }
        if let item = item(for: download) {
            if let url = item.destination {
                DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
            }
            onFinish?(item)
        }
        finish(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        update(download) { $0.failed = true }
        finish(download)
    }

    func reveal(_ item: Item) {
        if let destination = item.destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
    }

    func open(_ item: Item) {
        if let destination = item.destination, item.finished { NSWorkspace.shared.open(destination) }
    }

    /// Stops a download and removes its partial file.
    func cancel(_ item: Item) {
        guard let download = running[item.id] else { return }
        updateItem(item.id) {
            $0.failed = true
            $0.cancelled = true
        }
        finish(download)
        download.cancel { _ in }
        if let destination = item.destination { try? FileManager.default.removeItem(at: destination) }
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }

    private func item(for download: WKDownload) -> Item? {
        ids[ObjectIdentifier(download)].flatMap { id in items.first { $0.id == id } }
    }

    private func update(_ download: WKDownload, _ change: (inout Item) -> Void) {
        if let id = ids[ObjectIdentifier(download)] { updateItem(id, change) }
    }

    private func updateItem(_ id: UUID, _ change: (inout Item) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) { change(&items[index]) }
    }

    private func finish(_ download: WKDownload) {
        if let id = ids.removeValue(forKey: ObjectIdentifier(download)) {
            observations[id] = nil
            running[id] = nil
        }
    }

    private static func uniqueURL(in folder: URL, for filename: String) -> URL {
        let name = filename.isEmpty ? "Download" : filename
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
