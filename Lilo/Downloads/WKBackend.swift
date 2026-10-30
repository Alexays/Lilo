import Foundation
import WebKit
import OSLog

/// Handles WKDownload-based downloads (browser-initiated).
/// Pause is implemented as cancel+resumeData; resume restarts via WKWebView.resumeDownload.
@MainActor
final class WKBackend: NSObject {
    private static let logger = Logger(liloCategory: "WKBackend")

    var downloadsFolderProvider: () -> URL? = { nil }
    /// Set when the user wants to pick where each download goes: gets the proposed file and returns
    /// the chosen one, or nil to cancel the download. With `prompts`, it asks whatever the user's setting.
    var chooseDestination: ((URL, WKWebView?, _ prompts: Bool) async -> URL?)?
    /// chrome.downloads.onDeterminingFilename for a download about to start, nil when no extension suggests a name.
    var suggestFilename: ((WKDownload, DownloadItem) async -> FilenameSuggestion?)?
    var store: DownloadStore? {
        get { flight.store }
        set { flight.store = newValue }
    }
    var onUpdated: ((DownloadItem) -> Void)? {
        get { flight.onUpdated }
        set { flight.onUpdated = newValue }
    }

    /// Called once a download has its DownloadItem row.
    var onTracked: ((WKDownload, Int64) -> Void)?
    /// Called for a download that never gets a row (save panel cancelled, insert failed): WebKit cancels it.
    var onDropped: ((WKDownload) -> Void)?
    /// Called for a download that failed with resume data, with the failure, before it settles.
    var onResumableFailure: ((Int64, Error) -> Void)?

    /// Maps WKDownload to DownloadItem.id (set once destination is decided).
    private var activeDownloads: [WKDownload: Int64] = [:]
    /// Downloads whose file WebKit has not written yet: the first bytes quarantine it, so it never
    /// sits unquarantined while it downloads, nor once interrupted.
    private var unquarantined: [Int64: (path: String, source: String)] = [:]
    /// Destinations proposed to downloads still deciding where to go (extension suggestion, save panel): WebKit writes nothing there yet.
    private var pendingDestinations: Set<String> = []

    private let flight = InFlightDownloads()

    /// KVO on WKDownload.progress (the delegate has no progress callback). Raw KVO fires per network chunk, so a leading-edge gate
    /// throttles forwarding to one event per `progressInterval`, with no wakeups while no bytes flow.
    private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private nonisolated static let progressInterval: TimeInterval = 0.2

    /// Begin tracking a new browser-initiated download.
    func startTracking(_ download: WKDownload) {
        download.delegate = self
        // id is populated inside decideDestination callback; progress observation starts there too.
    }

    func pause(id: Int64) async {
        guard let download = activeDownloads.first(where: { $0.value == id })?.key else { return }
        let resumeData: Data? = await withCheckedContinuation { cont in
            download.cancel { data in cont.resume(returning: data) }
        }
        stopObservingProgress(for: download)
        activeDownloads.removeValue(forKey: download)
        // A finish or failure that landed during the await already settled the item: keep it.
        flight.settle(id) { item in
            guard item.state == .inProgress else { return false }
            DownloadQuarantine.stamp(path: item.destinationPath, source: item.url)
            item.resumeData = resumeData
            item.state = .paused
            return true
        }
    }

    /// Resumes a paused download, or an interrupted one that still carries resumeData (retry), in `webView`.
    /// Returns false when nothing was resumed (no resumeData, or no webView to host it).
    @discardableResult
    func resume(id: Int64, in webView: WKWebView?) async -> Bool {
        guard var item = try? store?.fetch(id: id),
              item.state == .paused || item.state == .interrupted,
              let resumeData = item.resumeData,
              let wv = webView else { return false }
        let download = await wv.resumeDownload(fromResumeData: resumeData)
        download.delegate = self
        activeDownloads[download] = id
        startObservingProgress(for: download)
        item.resumeData = nil
        item.state = .inProgress
        item.error = nil
        item.endedAt = nil
        try? store?.update(item)
        flight.begin(id, item)
        return true
    }

    func cancel(id: Int64) {
        guard let download = activeDownloads.first(where: { $0.value == id })?.key else { return }
        download.cancel { _ in }
        stopObservingProgress(for: download)
        activeDownloads.removeValue(forKey: download)
        flight.settle(id) { item in
            DownloadQuarantine.stamp(path: item.destinationPath, source: item.url)
            item.state = .interrupted; item.error = "Cancelled by user"; item.endedAt = Date()
            return true
        }
    }

    func isTracking(id: Int64) -> Bool {
        activeDownloads.values.contains(id)
    }

    var trackedIds: [Int64] { Array(activeDownloads.values) }

    // MARK: - Progress observation (WKDownloadDelegate has no progress callback)

    private func startObservingProgress(for download: WKDownload) {
        let key = ObjectIdentifier(download)
        let gate = ProgressEmitGate()
        progressObservations[key] = download.progress.observe(\.completedUnitCount) { [weak self, weak download] _, _ in
            guard gate.pass(interval: Self.progressInterval) else { return }
            Task { @MainActor [weak self, weak download] in
                guard let self, let download, let id = self.activeDownloads[download] else { return }
                if download.progress.completedUnitCount > 0, let file = self.unquarantined.removeValue(forKey: id) {
                    DownloadQuarantine.stamp(path: file.path, source: file.source)
                }
                self.flight.tick(id, bytesReceived: download.progress.completedUnitCount,
                                 totalBytes: download.progress.totalUnitCount)
            }
        }
    }

    private func stopObservingProgress(for download: WKDownload) {
        progressObservations.removeValue(forKey: ObjectIdentifier(download))?.invalidate()
        if let id = activeDownloads[download] { unquarantined[id] = nil }
    }

    private func destination(for proposed: URL, from webView: WKWebView?, prompts: Bool) async -> URL? {
        guard let chooseDestination else { return proposed }
        return await chooseDestination(proposed, webView, prompts)
    }

    /// Where the extensions' suggestion puts `item`, else its proposed destination, and whether the user picks the file:
    /// the suggested one is taken and the suggestion says "prompt".
    private func suggestedDestination(for download: WKDownload, item: DownloadItem, in directory: URL) async -> (url: URL, prompts: Bool) {
        var item = item
        item.profileId = store?.profileId
        guard let suggestion = await suggestFilename?(download, item) else { return (URL(fileURLWithPath: item.destinationPath), false) }
        return Self.destination(for: suggestion, in: directory)
    }

    /// Where an extension's suggestion puts a download, and whether the user picks the file (it exists and the suggestion says "prompt").
    nonisolated static func destination(for suggestion: FilenameSuggestion, in directory: URL) -> (url: URL, prompts: Bool) {
        let target = directory.appendingPathComponent(suggestion.filename)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: target.path) else { return (target, false) }
        switch suggestion.conflictAction {
        case "overwrite":
            // WebKit fails a download whose destination exists.
            try? FileManager.default.removeItem(at: target)
            return (target, false)
        case "prompt":
            return (target, true)
        default:
            return (resolveDestination(for: suggestion.filename, in: directory), false)
        }
    }

    /// Resolves a filename to a path in the given directory that neither exists nor is `reserved`.
    nonisolated static func resolveDestination(for suggestedFilename: String, in directory: URL, reserved: Set<String> = []) -> URL {
        let destination = directory.appendingPathComponent(suggestedFilename)
        var finalURL = destination
        var counter = 1
        while reserved.contains(finalURL.path) || FileManager.default.fileExists(atPath: finalURL.path) {
            let name = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            finalURL = destination.deletingLastPathComponent().appendingPathComponent(newName)
            counter += 1
        }
        return finalURL
    }
}

extension WKBackend: WKDownloadDelegate {
    nonisolated func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        // In-flight files may not exist yet: skipping their paths keeps two downloads of one name apart.
        let (dir, proposedURL) = await MainActor.run {
            let dir = resolvedDownloadsFolder(downloadsFolderProvider())
            let url = Self.resolveDestination(for: suggestedFilename, in: dir, reserved: pendingDestinations.union(flight.destinationPaths))
            pendingDestinations.insert(url.path)
            return (dir, url)
        }
        var item = DownloadItem(id: nil, url: response.url?.absoluteString ?? "",
            filename: suggestedFilename, destinationPath: proposedURL.path,
            bytesReceived: 0, totalBytes: response.expectedContentLength,
            state: .inProgress, startedAt: Date(), fileMissing: false)
        item.mimeType = response.mimeType
        let suggested = await suggestedDestination(for: download, item: item, in: dir)
        guard let finalURL = await destination(for: suggested.url, from: await download.webView, prompts: suggested.prompts) else {
            await MainActor.run {
                pendingDestinations.remove(proposedURL.path)
                onDropped?(download)
            }
            return nil
        }
        item.filename = finalURL.lastPathComponent
        item.destinationPath = finalURL.path

        let tracked: Bool = await MainActor.run { [item] in
            var item = item
            pendingDestinations.remove(proposedURL.path)
            guard (try? store?.insert(&item)) != nil, let id = item.id else {
                // Returning nil from decideDestination makes WebKit cancel silently, so leave a trail.
                Self.logger.error("download dropped before tracking (store nil or insert failed), WebKit will cancel: \(finalURL.lastPathComponent, privacy: .private) from \(response.url?.absoluteString ?? "nil", privacy: .private)")
                onDropped?(download)
                return false
            }
            activeDownloads[download] = id
            unquarantined[id] = (finalURL.path, item.url)
            onTracked?(download, id)
            startObservingProgress(for: download)
            flight.begin(id, item)
            return true
        }
        guard tracked else { return nil }
        return finalURL
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            stopObservingProgress(for: download)
            guard let id = activeDownloads[download] else { return }
            let settled = flight.settle(id) { item in
                DownloadQuarantine.stamp(path: item.destinationPath, source: item.url)
                item.state = .complete; item.endedAt = Date()
                if item.totalBytes > 0 { item.bytesReceived = item.totalBytes }  // throttled progress may lag the final bytes; snap to 100%
                return true
            }
            guard settled != nil else { return }
            activeDownloads.removeValue(forKey: download)
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in
            stopObservingProgress(for: download)
            if let id = activeDownloads[download], resumeData != nil { onResumableFailure?(id, error) }
            let settled = activeDownloads[download].flatMap { id in
                flight.settle(id) { item in
                    DownloadQuarantine.stamp(path: item.destinationPath, source: item.url)
                    item.state = .interrupted; item.error = error.localizedDescription; item.endedAt = Date(); item.resumeData = resumeData
                    return true
                }
            }
            guard settled != nil else {
                Self.logger.error("download failed before it was tracked: \(error.localizedDescription, privacy: .public)")
                return
            }
            activeDownloads.removeValue(forKey: download)
        }
    }
}
