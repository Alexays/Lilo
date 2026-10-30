import Foundation
import WebKit
import AppKit
import UserNotifications
import OSLog

/// A download's filename relative to the downloads folder and Chrome's conflictAction for it, as an extension suggests them.
typealias FilenameSuggestion = (filename: String, conflictAction: String)

/// Façade coordinating WKBackend and URLSessionBackend.
/// All callers interact with this class; backend selection is internal.
@MainActor
final class DownloadManager {
    private static let logger = Logger(liloCategory: "DownloadManager")

    private let wkBackend = WKBackend()
    private let urlSessionBackend = URLSessionBackend()
    private(set) var store: DownloadStore?

    /// Read at each download start, so a settings change applies to the next download.
    var downloadsFolderProvider: () -> URL? = { nil } {
        didSet {
            wkBackend.downloadsFolderProvider = downloadsFolderProvider
            urlSessionBackend.downloadsFolderProvider = downloadsFolderProvider
        }
    }
    var settingsFolder: URL? { downloadsFolderProvider() }

    var chooseDestination: ((URL, WKWebView?, _ prompts: Bool) async -> URL?)? {
        get { wkBackend.chooseDestination }
        set { wkBackend.chooseDestination = newValue }
    }

    /// chrome.downloads.onDeterminingFilename for a browser download about to start, never asked for a private space's.
    var suggestFilename: ((DownloadItem) async -> FilenameSuggestion?)?

    weak var webView: WKWebView? {
        didSet { wkBackend.webView = webView }
    }

    /// Observers called on every DownloadItem state change, each with the token that removes it.
    private var observers: [(token: UUID, notify: (DownloadItem) -> Void)] = []

    /// Called with the id and the profile of a download record erased (not routed through `observers`/onUpdated). Used to
    /// fire `chrome.downloads.onErased`.
    var onErased: ((Int64, UUID?) -> Void)?

    private(set) var quickLookItemURL: URL?

    private struct SpeedSample {
        var lastBytes: Int64
        var lastTime: Date
        var smoothedSpeed: Int64  // exponential moving average, bytes/sec
    }
    private var speedSamples: [Int64: SpeedSample] = [:]
    /// Automatic resumes spent per download; a drop past the last delay waits for the user's Retry.
    private var autoResumes: [Int64: Int] = [:]
    /// Interrupted downloads with an automatic resume ahead: their failure is not notified.
    private var pendingAutoResumes: Set<Int64> = []
    private static let autoResumeDelays: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]
    private static let resumableNetworkErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed
    ]
    private let dockController: DownloadDockProgressController?

    /// Private-space downloads awaiting their row, and the rows they got. The rows are erased when
    /// the space closes so private downloads leave no entry in the persistent list.
    private var pendingPrivateSpaceIds: [WKDownload: UUID] = [:]
    private var privateDownloadIds: [UUID: [Int64]] = [:]
    /// Pending downloads of a private space that closed before they got a row: cancelled and erased once tracked.
    private var forgottenPendingDownloads: [WKDownload: UUID] = [:]

    init(dockController: DownloadDockProgressController? = DownloadDockProgressController()) {
        self.dockController = dockController
        wkBackend.onUpdated = { [weak self] item in self?.notifyObservers(item) }
        urlSessionBackend.onUpdated = { [weak self] item in self?.notifyObservers(item) }
        wkBackend.onResumableFailure = { [weak self] id, error in self?.resumeAfterNetworkDrop(id: id, error: error) }
        urlSessionBackend.onResumableFailure = { [weak self] id, error in self?.resumeAfterNetworkDrop(id: id, error: error) }
        wkBackend.onTracked = { [weak self] download, id in
            guard let self else { return }
            if let spaceId = pendingPrivateSpaceIds.removeValue(forKey: download) {
                privateDownloadIds[spaceId, default: []].append(id)
            } else if let spaceId = forgottenPendingDownloads.removeValue(forKey: download) {
                privateDownloadIds[spaceId, default: []].append(id)
                // Deferred: the backend finishes registering the download after this callback returns.
                Task { @MainActor [weak self] in self?.forgetPrivateDownloads(inSpace: spaceId) }
            }
        }
        wkBackend.suggestFilename = { [weak self] download, item in
            guard let self, pendingPrivateSpaceIds[download] == nil, forgottenPendingDownloads[download] == nil else { return nil }
            return await suggestFilename?(item)
        }
        // A private download that never got a row is not tracked: nothing else would let it go.
        wkBackend.onDropped = { [weak self] download in
            self?.pendingPrivateSpaceIds.removeValue(forKey: download)
            self?.forgottenPendingDownloads.removeValue(forKey: download)
        }
        dockController?.attach(to: self)
    }

    @discardableResult
    func addObserver(_ notify: @escaping (DownloadItem) -> Void) -> UUID {
        let token = UUID()
        observers.append((token, notify))
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeAll { $0.token == token }
    }

    /// Profile databases already recovered this run: once attached, their in-progress rows are live downloads.
    private var recoveredDatabasePaths: Set<String> = []

    /// Inject the profile store after profile activation.
    func setStore(_ store: DownloadStore) {
        self.store = store
        wkBackend.store = store
        urlSessionBackend.store = store
        guard recoveredDatabasePaths.insert(store.dbPool.path).inserted else { return }
        loggingPersistenceError("download.recoverFromCrash") { try store.recoverFromCrash() }
    }

    // MARK: - Browser downloads (WKDownload)

    func startDownload(_ download: WKDownload, privateSpaceId: UUID? = nil) {
        if let privateSpaceId { pendingPrivateSpaceIds[download] = privateSpaceId }
        wkBackend.startTracking(download)
    }

    /// Cancels the private space's in-flight downloads and erases its rows. Files already on disk stay.
    /// The ids stay marked private until erased, so observers can still recognize them.
    func forgetPrivateDownloads(inSpace spaceId: UUID) {
        for (download, pendingSpaceId) in pendingPrivateSpaceIds where pendingSpaceId == spaceId {
            pendingPrivateSpaceIds.removeValue(forKey: download)
            forgottenPendingDownloads[download] = spaceId
        }
        for id in privateDownloadIds[spaceId] ?? [] {
            if wkBackend.isTracking(id: id) { wkBackend.cancel(id: id) }
            loggingPersistenceError("download.erasePrivate[\(id)]") { try erase(id: id) }
        }
        privateDownloadIds[spaceId] = nil
    }

    /// Private-space downloads are never exposed to extensions.
    func isPrivateDownload(id: Int64) -> Bool {
        privateDownloadIds.values.contains { $0.contains(id) }
    }

    // MARK: - Extension downloads (chrome.downloads.download)

    @discardableResult
    /// `destination` overrides the downloads folder and replaces any file there (see URLSessionBackend).
    func startExtensionDownload(request: URLRequest, suggestedFilename: String, destination: URL? = nil) throws -> Int64 {
        try urlSessionBackend.startDownload(request: request, suggestedFilename: suggestedFilename, destination: destination)
    }

    // MARK: - Blob / data saves (WKUIDelegatePrivate saveDataToFile)

    /// Writes raw data (a blob/canvas/generated file the page handed us) to the downloads folder and
    /// records it as a completed download so it shows up in the downloads panel. The write runs off
    /// the main thread; the returned task finishes once the row is recorded.
    @discardableResult
    func saveData(
        _ data: Data, suggestedFilename: String, mimeType: String, originatingURL: URL, privateSpaceId: UUID? = nil
    ) -> Task<Void, Never> {
        let folder = resolvedDownloadsFolder(settingsFolder)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let source = originatingURL.absoluteString
        return Task { @MainActor in
            let written = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
                let destination = WKBackend.resolveDestination(for: name, in: folder)
                do {
                    try data.write(to: destination, options: .withoutOverwriting)
                } catch {
                    return .failure(error)
                }
                DownloadQuarantine.stamp(path: destination.path, source: source)
                return .success(destination)
            }.value
            let destination: URL
            switch written {
            case .success(let url): destination = url
            case .failure(let error):
                Self.logger.error("Failed to save data to file: \(error.localizedDescription)")
                return
            }
            var item = DownloadItem(
                id: nil,
                url: source,
                filename: destination.lastPathComponent,
                destinationPath: destination.path,
                bytesReceived: Int64(data.count),
                totalBytes: Int64(data.count),
                state: .complete,
                error: nil,
                resumeData: nil,
                startedAt: Date(),
                endedAt: Date(),
                mimeType: mimeType.isEmpty ? nil : mimeType,
                fileMissing: false,
                source: "blob"
            )
            // The file is already on disk; a lost row only hides it from the list, so notifyObservers
            // still runs and the completion notification fires either way.
            loggingPersistenceError("download.insert[\(destination.lastPathComponent)]") {
                try store?.insert(&item)
            }
            if let privateSpaceId, let id = item.id { privateDownloadIds[privateSpaceId, default: []].append(id) }
            notifyObservers(item)
        }
    }

    // MARK: - Lifecycle control

    var activeDownloadCount: Int {
        wkBackend.trackedIds.count + urlSessionBackend.trackedIds.count
    }

    /// Quit path: cancels every in-flight download producing resume data and persists it as
    /// paused, so the next launch resumes from the partial bytes instead of restarting.
    func pauseAllForQuit() async {
        // Each pause waits on the backend producing resume data; run them concurrently so quitting
        // with N downloads in flight costs one wait, not N.
        let pauses = wkBackend.trackedIds.map { id in
            Task { @MainActor in await self.wkBackend.pause(id: id) }
        } + urlSessionBackend.trackedIds.map { id in
            Task { @MainActor in await self.urlSessionBackend.pause(id: id) }
        }
        for pause in pauses { await pause.value }
    }

    func pause(id: Int64) async {
        if wkBackend.isTracking(id: id) { await wkBackend.pause(id: id) } else if urlSessionBackend.isTracking(id: id) { await urlSessionBackend.pause(id: id) }
    }

    func resume(id: Int64) async {
        guard var item = try? store?.fetch(id: id), item.state == .paused else { return }
        var resumed = false
        if item.source == "wk" {
            resumed = await wkBackend.resume(id: id)
        } else if item.resumeData != nil {
            do {
                try urlSessionBackend.resume(id: id)
                resumed = true
            } catch {
                Self.logger.error("download resume failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !resumed else { return }
        // A row left paused keeps offering a Resume that can never work.
        item.state = .interrupted; item.error = "Could not resume download"; item.endedAt = Date()
        try? store?.update(item); notifyObservers(item)
    }

    func cancel(id: Int64) async {
        stop(id: id)
    }

    /// Ends a download still in flight or paused: its backend lets go of it and observers see it interrupted.
    private func stop(id: Int64) {
        if wkBackend.isTracking(id: id) { wkBackend.cancel(id: id) } else if urlSessionBackend.isTracking(id: id) { urlSessionBackend.cancel(id: id) } else {
            guard var item = try? store?.fetch(id: id),
                  item.state == .inProgress || item.state == .paused else { return }
            item.state = .interrupted; item.error = "Cancelled by user"; item.endedAt = Date()
            loggingPersistenceError("download.cancel[\(id)]") { try store?.update(item) }
            notifyObservers(item)
        }
    }

    // MARK: - File operations

    func openFile(id: Int64) {
        guard let item = try? store?.fetch(id: id) else { return }
        let url = URL(fileURLWithPath: item.destinationPath)
        if DownloadQuarantine.isRisky(url), DownloadQuarantine.isQuarantined(url),
           !confirmOpenRiskyDownload(filename: item.filename) {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Pre-Gatekeeper confirmation for a still-quarantined executable type.
    private func confirmOpenRiskyDownload(filename: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open this download?".localized
        alert.informativeText = String(
            format: "%@ was downloaded from the internet. Open it anyway?".localized, filename)
        alert.addButton(withTitle: "Open".localized)
        alert.addButton(withTitle: "Cancel".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showInFinder(id: Int64) {
        guard let item = try? store?.fetch(id: id) else { return }; NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.destinationPath)])
    }

    func showDownloadsFolder() {
        NSWorkspace.shared.open(resolvedDownloadsFolder(settingsFolder))
    }

    func removeFile(id: Int64) throws {
        guard let item = try? store?.fetch(id: id) else { return }
        guard item.state == .complete || item.state == .interrupted else { return }
        let url = URL(fileURLWithPath: item.destinationPath)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try store?.markFileMissing(id: id)
        if let updated = try? store?.fetch(id: id) { notifyObservers(updated) }
    }

    /// A download erased while in flight or paused is stopped first, as in Chrome, so nothing keeps
    /// ticking or badging the Dock for a row that is gone.
    func erase(id: Int64) throws {
        stop(id: id)
        pendingAutoResumes.remove(id); autoResumes[id] = nil
        try store?.delete(id: id)
        onErased?(id, store?.profileId)
    }

    /// As Chrome does, a download the network dropped resumes from its partial bytes a few times, each
    /// after a longer pause and once the network is up.
    private func resumeAfterNetworkDrop(id: Int64, error: Error) {
        let e = error as NSError
        let attempt = autoResumes[id, default: 0]
        guard e.domain == NSURLErrorDomain, Self.resumableNetworkErrorCodes.contains(e.code),
              attempt < Self.autoResumeDelays.count else { return }
        autoResumes[id] = attempt + 1
        pendingAutoResumes.insert(id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.autoResumeDelays[attempt])
            NetworkPathStatus.shared.runWhenSatisfied {
                Task { @MainActor [weak self] in
                    guard let self, self.pendingAutoResumes.remove(id) != nil else { return }
                    try? await self.retryDownload(id: id)
                }
            }
        }
    }

    /// Retries an interrupted download. When the row still carries resumeData the download is
    /// resumed from the partial bytes into its original destination; otherwise it restarts
    /// fresh (a wk-source retry without a webView also falls back to a fresh start).
    func retryDownload(id: Int64) async throws {
        pendingAutoResumes.remove(id)
        guard let item = try? store?.fetch(id: id),
              item.state == .interrupted else { return }
        if item.resumeData != nil {
            if item.source == "wk" {
                if await wkBackend.resume(id: id) { return }
            } else {
                try urlSessionBackend.resume(id: id)
                return
            }
        }
        guard let url = URL(string: item.url) else { return }
        var request = URLRequest(url: url)
        // A signed-in download needs the site's cookies, which live in WebKit's store and not in URLSession's.
        if let cookieStore = webView?.configuration.websiteDataStore.httpCookieStore, let host = url.host?.lowercased() {
            let cookies = await cookieStore.allCookies().filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path)
                    && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate ?? .distantFuture) > Date()
            }
            request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
        }
        try startExtensionDownload(request: request, suggestedFilename: item.filename)
    }

    func fileIcon(id: Int64, size: Int) -> String? {
        guard let item = try? store?.fetch(id: id) else { return nil }
        let url = URL(fileURLWithPath: item.destinationPath)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let iconSize = CGFloat(size > 0 ? size : 32)
        guard let rep = icon.bestRepresentation(
            for: NSRect(origin: .zero, size: CGSize(width: iconSize, height: iconSize)),
            context: nil, hints: nil
        ),
        let cgImage = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return data.base64EncodedString()
    }

    func prepareQuickLook(id: Int64) -> URL? {
        guard let item = try? store?.fetch(id: id), item.state == .complete, !item.fileMissing else { return nil }
        let url = URL(fileURLWithPath: item.destinationPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        quickLookItemURL = url; return url
    }

    func fileURL(id: Int64) -> URL? {
        guard let item = try? store?.fetch(id: id),
              item.state == .complete, !item.fileMissing else { return nil }
        let url = URL(fileURLWithPath: item.destinationPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private (internal for testing)

    func updateSpeed(for item: DownloadItem, now: Date = Date()) {
        guard let id = item.id else { return }
        guard item.state == .inProgress else {
            speedSamples.removeValue(forKey: id)
            return
        }
        if var sample = speedSamples[id] {
            let elapsed = now.timeIntervalSince(sample.lastTime)
            guard elapsed >= 0.3 else { return }
            let instant = max(0, Int64(Double(item.bytesReceived - sample.lastBytes) / elapsed))
            sample.smoothedSpeed = Int64(0.3 * Double(instant) + 0.7 * Double(sample.smoothedSpeed))
            sample.lastBytes = item.bytesReceived
            sample.lastTime = now
            speedSamples[id] = sample
        } else {
            speedSamples[id] = SpeedSample(lastBytes: item.bytesReceived, lastTime: now, smoothedSpeed: 0)
        }
    }

    func augmentedBridgeData(for item: DownloadItem) -> [String: Any] {
        var data = item.bridgeData
        guard let id = item.id, let sample = speedSamples[id], sample.smoothedSpeed > 0 else { return data }
        data["speedBytesPerSec"] = sample.smoothedSpeed
        if item.totalBytes > 0 {
            let remaining = item.totalBytes - item.bytesReceived
            data["eta"] = max(0.0, Double(remaining) / Double(sample.smoothedSpeed))
        }
        return data
    }

    private func sendDownloadNotification(for item: DownloadItem) {
        guard item.state == .complete || item.state == .interrupted, !item.fileMissing,
              !pendingAutoResumes.contains(item.id ?? 0) else { return }
        // UNUserNotificationCenter.current() raises NSInternalInconsistencyException outside a
        // real .app bundle (swift test runs in xctest), which kills the whole test run.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        let content = UNMutableNotificationContent()
        content.sound = item.state == .complete ? .default : nil

        if item.state == .complete {
            content.title = "Download Complete".localized; content.body = item.filename
        } else {
            guard let error = item.error, !error.localizedCaseInsensitiveContains("cancel") else { return }
            content.title = "Download Failed".localized; content.body = "\(item.filename): \(error)"
        }

        let identifier = "download-\(item.id ?? 0)-\(item.state.rawValue)"
        UNUserNotificationCenter.requestAuthorizationAndAdd(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    private func notifyObservers(_ item: DownloadItem) {
        updateSpeed(for: item)
        observers.forEach { $0.notify(item) }
        sendDownloadNotification(for: item)
    }
}
