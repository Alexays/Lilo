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
    /// The user agent pages get, which a retry sends in place of CFNetwork's. WebKit only builds it inside a web view.
    private static let pageUserAgent: String? = {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = WKEngineFactory.safariApplicationName
        let webView = WKWebView(frame: .zero, configuration: configuration)
        return webView.responds(to: NSSelectorFromString("_userAgent")) ? webView.value(forKey: "_userAgent") as? String : nil
    }()

    /// The backends of one profile store. Row ids are per database, so each store gets its own: two profiles' downloads
    /// may share an id.
    @MainActor private struct Lane {
        let wk = WKBackend()
        let url = URLSessionBackend()
    }
    private var lanes: [ObjectIdentifier: Lane] = [:]

    /// Read at each download start, so a settings change applies to the next download.
    var downloadsFolderProvider: () -> URL? = { nil }
    var settingsFolder: URL? { downloadsFolderProvider() }

    var chooseDestination: ((URL, WKWebView?, _ prompts: Bool) async -> URL?)?

    /// chrome.downloads.onDeterminingFilename for a browser download about to start, never asked for a private space's.
    var suggestFilename: ((DownloadItem) async -> FilenameSuggestion?)?

    /// The active tab's web view, which hosts a WKDownload resume when it browses with the download's data store.
    weak var webView: WKWebView?

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
    private var speedSamples: [DownloadKey: SpeedSample] = [:]
    /// Automatic resumes spent per download; a drop past the last delay waits for the user's Retry.
    private var autoResumes: [DownloadKey: Int] = [:]
    /// Interrupted downloads with an automatic resume ahead: their failure is not notified.
    private var pendingAutoResumes: Set<DownloadKey> = []
    private static let autoResumeDelays: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]
    private static let resumableNetworkErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed
    ]
    private let dockController: DownloadDockProgressController?

    /// Private-space downloads awaiting their row, and the rows they got. The rows are erased when
    /// the space closes so private downloads leave no entry in the persistent list.
    private var pendingPrivateSpaceIds: [WKDownload: UUID] = [:]
    private var privateDownloadIds: [UUID: [DownloadKey]] = [:]
    /// Pending downloads of a private space that closed before they got a row: cancelled and erased once tracked.
    private var forgottenPendingDownloads: [WKDownload: UUID] = [:]
    /// Each private space's website data store, where its downloads resume and find their cookies.
    private var privateDataStores: [UUID: WKWebsiteDataStore] = [:]

    init(dockController: DownloadDockProgressController? = DownloadDockProgressController()) {
        self.dockController = dockController
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

    /// Readies a profile's store as its profile activates: the downloads its last run left in flight become interrupted.
    func attach(_ store: DownloadStore) {
        _ = lane(for: store)
    }

    private func lane(for store: DownloadStore) -> Lane {
        let laneKey = ObjectIdentifier(store)
        // Backends hold their store weakly: a lane that outlived its store is not reused for another at the same address.
        if let lane = lanes[laneKey], lane.wk.store === store { return lane }
        let lane = Lane()
        lanes[laneKey] = lane
        let profileId = store.profileId
        lane.wk.store = store
        lane.url.store = store
        lane.wk.onUpdated = { [weak self] item in self?.notifyObservers(item) }
        lane.url.onUpdated = { [weak self] item in
            guard let self else { return }
            // WKBackend records a browser download's origin itself; a private Space's is never recorded.
            if item.state == .complete, let key = item.key, !privateDownloadIds.values.contains(where: { $0.contains(key) }) {
                DownloadQuarantine.recordOrigin(path: item.destinationPath, urls: [item.url])
            }
            notifyObservers(item)
        }
        lane.wk.onResumableFailure = { [weak self, weak store] id, error in
            if let store { self?.resumeAfterNetworkDrop(id: id, in: store, error: error) }
        }
        lane.url.onResumableFailure = lane.wk.onResumableFailure
        lane.wk.downloadsFolderProvider = { [weak self] in self?.downloadsFolderProvider() }
        lane.url.downloadsFolderProvider = lane.wk.downloadsFolderProvider
        lane.wk.chooseDestination = { [weak self] proposed, webView, prompts in
            guard let chooseDestination = self?.chooseDestination else { return proposed }
            return await chooseDestination(proposed, webView, prompts)
        }
        lane.wk.onTracked = { [weak self] download, id in
            guard let self else { return }
            let key = DownloadKey(profileId: profileId, id: id)
            if let spaceId = pendingPrivateSpaceIds.removeValue(forKey: download) {
                privateDownloadIds[spaceId, default: []].append(key)
            } else if let spaceId = forgottenPendingDownloads.removeValue(forKey: download) {
                privateDownloadIds[spaceId, default: []].append(key)
                // Deferred: the backend finishes registering the download after this callback returns.
                Task { @MainActor [weak self] in self?.forgetPrivateDownloads(inSpace: spaceId) }
            }
        }
        lane.wk.suggestFilename = { [weak self] download, item in
            guard let self, pendingPrivateSpaceIds[download] == nil, forgottenPendingDownloads[download] == nil else { return nil }
            return await suggestFilename?(item)
        }
        // A private download that never got a row is not tracked: nothing else would let it go.
        lane.wk.onDropped = { [weak self] download in
            self?.pendingPrivateSpaceIds.removeValue(forKey: download)
            self?.forgottenPendingDownloads.removeValue(forKey: download)
        }
        if recoveredDatabasePaths.insert(store.dbPool.path).inserted {
            loggingPersistenceError("download.recoverFromCrash") { try store.recoverFromCrash() }
        }
        return lane
    }

    // MARK: - Browser downloads (WKDownload)

    /// The row goes to `store`, the downloading tab's profile store.
    func startDownload(_ download: WKDownload, in store: DownloadStore, privateSpaceId: UUID? = nil) {
        if let privateSpaceId {
            pendingPrivateSpaceIds[download] = privateSpaceId
            download.webView.map { privateDataStores[privateSpaceId] = $0.configuration.websiteDataStore }
        }
        lane(for: store).wk.startTracking(download)
    }

    /// Cancels the private space's in-flight downloads and erases its rows. Files already on disk stay.
    /// The ids stay marked private until erased, so observers can still recognize them.
    func forgetPrivateDownloads(inSpace spaceId: UUID) {
        for (download, pendingSpaceId) in pendingPrivateSpaceIds where pendingSpaceId == spaceId {
            pendingPrivateSpaceIds.removeValue(forKey: download)
            forgottenPendingDownloads[download] = spaceId
        }
        for key in privateDownloadIds[spaceId] ?? [] {
            guard let store = lanes.values.lazy.compactMap(\.wk.store).first(where: { $0.profileId == key.profileId }) else { continue }
            loggingPersistenceError("download.erasePrivate[\(key.id)]") { try erase(id: key.id, in: store) }
        }
        privateDownloadIds[spaceId] = nil
        privateDataStores[spaceId] = nil
    }

    /// Private-space downloads are never exposed to extensions.
    func isPrivateDownload(id: Int64, profileId: UUID?) -> Bool {
        let key = DownloadKey(profileId: profileId, id: id)
        return privateDownloadIds.values.contains { $0.contains(key) }
    }

    // MARK: - Extension downloads (chrome.downloads.download)

    @discardableResult
    /// `destination` overrides the downloads folder and replaces any file there (see URLSessionBackend).
    func startExtensionDownload(request: URLRequest, suggestedFilename: String, destination: URL? = nil, in store: DownloadStore) throws -> Int64 {
        try lane(for: store).url.startDownload(request: request, suggestedFilename: suggestedFilename, destination: destination)
    }

    // MARK: - Blob / data saves (WKUIDelegatePrivate saveDataToFile)

    /// Writes raw data (a blob/canvas/generated file the page handed us) where a download of it would go, after the
    /// extensions' suggestion and the save panel, and records it as a completed download so it shows up in the downloads
    /// panel. The write runs off the main thread; the returned task finishes once the row is recorded.
    @discardableResult
    func saveData(
        _ data: Data, suggestedFilename: String, mimeType: String, originatingURL: URL, webView: WKWebView? = nil, in store: DownloadStore, privateSpaceId: UUID? = nil
    ) -> Task<Void, Never> {
        attach(store)
        let folder = resolvedDownloadsFolder(settingsFolder)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let proposed = WKBackend.resolveDestination(for: name, in: folder)
        var item = DownloadItem(
            id: nil, url: originatingURL.absoluteString, filename: name, destinationPath: proposed.path,
            bytesReceived: 0, totalBytes: Int64(data.count), state: .inProgress, startedAt: Date(), fileMissing: false
        )
        item.mimeType = mimeType.isEmpty ? nil : mimeType
        item.source = "blob"
        item.profileId = store.profileId
        return Task { @MainActor [item] in
            var item = item
            let suggestion = privateSpaceId == nil ? await suggestFilename?(item) : nil
            let suggested = suggestion.map { WKBackend.destination(for: $0, in: folder) } ?? (url: proposed, prompts: false)
            let chosen: URL
            if let chooseDestination {
                guard let url = await chooseDestination(suggested.url, webView, suggested.prompts) else { return }
                chosen = url
            } else {
                chosen = suggested.url
            }
            let source = item.url
            let written = await Task.detached(priority: .utility) { () -> Result<URL, Error> in
                // Resolved again at write time, as another save may have taken the proposed name meanwhile. A file
                // the user or an extension picked may replace one there.
                let unchanged = chosen == proposed
                let destination = unchanged ? WKBackend.resolveDestination(for: name, in: folder) : chosen
                do {
                    try data.write(to: destination, options: unchanged ? .withoutOverwriting : [])
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
            item.filename = destination.lastPathComponent
            item.destinationPath = destination.path
            item.bytesReceived = Int64(data.count)
            item.state = .complete
            item.endedAt = Date()
            // The file is already on disk; a lost row only hides it from the list, so notifyObservers
            // still runs and the completion notification fires either way.
            loggingPersistenceError("download.insert[\(destination.lastPathComponent)]") {
                try store.insert(&item)
            }
            if let privateSpaceId, let key = item.key { privateDownloadIds[privateSpaceId, default: []].append(key) }
            notifyObservers(item)
        }
    }

    // MARK: - Lifecycle control

    var activeDownloadCount: Int {
        lanes.values.reduce(0) { $0 + $1.wk.trackedIds.count + $1.url.trackedIds.count }
    }

    /// Quit path: cancels every in-flight download producing resume data and persists it as
    /// paused, so the next launch resumes from the partial bytes instead of restarting.
    func pauseAllForQuit() async {
        // Each pause waits on the backend producing resume data; run them concurrently so quitting
        // with N downloads in flight costs one wait, not N.
        let pauses = lanes.values.flatMap { lane in
            lane.wk.trackedIds.map { id in Task { @MainActor in await lane.wk.pause(id: id) } }
                + lane.url.trackedIds.map { id in Task { @MainActor in await lane.url.pause(id: id) } }
        }
        for pause in pauses { await pause.value }
    }

    func pause(id: Int64, in store: DownloadStore) async {
        let lane = lane(for: store)
        if lane.wk.isTracking(id: id) { await lane.wk.pause(id: id) } else if lane.url.isTracking(id: id) { await lane.url.pause(id: id) }
    }

    func resume(id: Int64, in store: DownloadStore) async {
        guard var item = try? store.fetch(id: id), item.state == .paused else { return }
        let lane = lane(for: store)
        var resumed = false
        if item.source == "wk" {
            resumed = await lane.wk.resume(id: id, in: resumeHost(for: DownloadKey(profileId: store.profileId, id: id)))
        } else if item.resumeData != nil {
            do {
                try lane.url.resume(id: id)
                resumed = true
            } catch {
                Self.logger.error("download resume failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !resumed else { return }
        // A row left paused keeps offering a Resume that can never work.
        item.state = .interrupted; item.error = "Could not resume download"; item.endedAt = Date()
        try? store.update(item); notifyObservers(item)
    }

    func cancel(id: Int64, in store: DownloadStore) async {
        stop(id: id, in: store)
    }

    /// Ends a download still in flight or paused: its backend lets go of it and observers see it interrupted.
    private func stop(id: Int64, in store: DownloadStore) {
        let lane = lane(for: store)
        if lane.wk.isTracking(id: id) { lane.wk.cancel(id: id) } else if lane.url.isTracking(id: id) { lane.url.cancel(id: id) } else {
            guard var item = try? store.fetch(id: id),
                  item.state == .inProgress || item.state == .paused else { return }
            item.state = .interrupted; item.error = "Cancelled by user"; item.endedAt = Date()
            // A paused browser download keeps its partial bytes under the final name, as an in-flight one does.
            if item.source == "wk" {
                try? FileManager.default.removeItem(atPath: item.destinationPath)
                item.fileMissing = true
            }
            loggingPersistenceError("download.cancel[\(id)]") { try store.update(item) }
            notifyObservers(item)
        }
    }

    // MARK: - File operations

    func openFile(id: Int64, in store: DownloadStore) {
        guard let item = try? store.fetch(id: id) else { return }
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

    func showInFinder(id: Int64, in store: DownloadStore) {
        guard let item = try? store.fetch(id: id) else { return }; NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.destinationPath)])
    }

    func showDownloadsFolder() {
        NSWorkspace.shared.open(resolvedDownloadsFolder(settingsFolder))
    }

    func removeFile(id: Int64, in store: DownloadStore) throws {
        guard let item = try? store.fetch(id: id) else { return }
        guard item.state == .complete || item.state == .interrupted else { return }
        let url = URL(fileURLWithPath: item.destinationPath)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try store.markFileMissing(id: id)
        if let updated = try? store.fetch(id: id) { notifyObservers(updated) }
    }

    /// A download erased while in flight or paused is stopped first, as in Chrome, so nothing keeps
    /// ticking or badging the Dock for a row that is gone.
    func erase(id: Int64, in store: DownloadStore) throws {
        stop(id: id, in: store)
        // The partial bytes of a browser download that failed go with it, as Chrome's do.
        if let item = try? store.fetch(id: id), item.source == "wk", item.state == .interrupted, !item.fileMissing {
            try? FileManager.default.removeItem(atPath: item.destinationPath)
        }
        let key = DownloadKey(profileId: store.profileId, id: id)
        pendingAutoResumes.remove(key); autoResumes[key] = nil
        try store.delete(id: id)
        onErased?(id, store.profileId)
    }

    /// As Chrome does, a download the network dropped resumes from its partial bytes a few times, each
    /// after a longer pause and once the network is up.
    private func resumeAfterNetworkDrop(id: Int64, in store: DownloadStore, error: Error) {
        let e = error as NSError
        let key = DownloadKey(profileId: store.profileId, id: id)
        let attempt = autoResumes[key, default: 0]
        guard e.domain == NSURLErrorDomain, Self.resumableNetworkErrorCodes.contains(e.code),
              attempt < Self.autoResumeDelays.count else { return }
        autoResumes[key] = attempt + 1
        pendingAutoResumes.insert(key)
        Task { @MainActor [weak self, weak store] in
            try? await Task.sleep(for: Self.autoResumeDelays[attempt])
            NetworkPathStatus.shared.runWhenSatisfied {
                Task { @MainActor [weak self, weak store] in
                    guard let self, let store, self.pendingAutoResumes.remove(key) != nil else { return }
                    try? await self.retryDownload(id: id, in: store)
                }
            }
        }
    }

    /// The website data store a download belongs to: its private space's, else its profile's. Nil once its private space's is gone.
    private func dataStore(ofDownload key: DownloadKey) -> WKWebsiteDataStore? {
        if let spaceId = privateDownloadIds.first(where: { $0.value.contains(key) })?.key { return privateDataStores[spaceId] }
        return key.profileId.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
    }

    /// `webView` when it browses with the download's data store: resumed in another, a download would carry another
    /// profile's or space's cookies, and a private one would land in the persistent store or the reverse.
    private func resumeHost(for key: DownloadKey) -> WKWebView? {
        guard let webView, let expected = dataStore(ofDownload: key) else { return nil }
        let current = webView.configuration.websiteDataStore
        let matches = current === expected || current.isPersistent && expected.isPersistent && current.identifier == expected.identifier
        return matches ? webView : nil
    }

    /// Retries an interrupted download. When the row still carries resumeData the download is
    /// resumed from the partial bytes into its original destination; otherwise it restarts
    /// fresh (a wk-source retry without a web view of its data store also falls back to a fresh start).
    func retryDownload(id: Int64, in store: DownloadStore) async throws {
        let key = DownloadKey(profileId: store.profileId, id: id)
        pendingAutoResumes.remove(key)
        guard let item = try? store.fetch(id: id),
              item.state == .interrupted else { return }
        let lane = lane(for: store)
        if item.resumeData != nil {
            if item.source == "wk" {
                if await lane.wk.resume(id: id, in: resumeHost(for: key)) { return }
            } else {
                try lane.url.resume(id: id)
                return
            }
        }
        guard let url = URL(string: item.url) else { return }
        // A browser download starting over drops its partial bytes, so it takes the original name again.
        if item.source == "wk", !item.fileMissing {
            try? FileManager.default.removeItem(atPath: item.destinationPath)
            try? store.markFileMissing(id: id)
        }
        var request = URLRequest(url: url)
        // A signed-in download needs the site's cookies, which live in WebKit's store and not in URLSession's.
        if let cookieStore = dataStore(ofDownload: key)?.httpCookieStore {
            request.httpShouldHandleCookies = false
            request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: await cookieStore.cookies(for: url))
        }
        request.setValue(Self.pageUserAgent, forHTTPHeaderField: "User-Agent")
        let retryId = try startExtensionDownload(request: request, suggestedFilename: item.filename, in: store)
        // The new row of a private download is forgotten with its space too.
        if let spaceId = privateDownloadIds.first(where: { $0.value.contains(key) })?.key {
            privateDownloadIds[spaceId]?.append(DownloadKey(profileId: store.profileId, id: retryId))
        }
    }

    func fileIcon(id: Int64, size: Int, in store: DownloadStore) -> String? {
        guard let item = try? store.fetch(id: id) else { return nil }
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

    func prepareQuickLook(id: Int64, in store: DownloadStore) -> URL? {
        guard let item = try? store.fetch(id: id), item.state == .complete, !item.fileMissing else { return nil }
        let url = URL(fileURLWithPath: item.destinationPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        quickLookItemURL = url; return url
    }

    func fileURL(id: Int64, in store: DownloadStore) -> URL? {
        guard let item = try? store.fetch(id: id),
              item.state == .complete, !item.fileMissing else { return nil }
        let url = URL(fileURLWithPath: item.destinationPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Private (internal for testing)

    func updateSpeed(for item: DownloadItem, now: Date = Date()) {
        guard let key = item.key else { return }
        guard item.state == .inProgress else {
            speedSamples.removeValue(forKey: key)
            return
        }
        if var sample = speedSamples[key] {
            let elapsed = now.timeIntervalSince(sample.lastTime)
            guard elapsed >= 0.3 else { return }
            let instant = max(0, Int64(Double(item.bytesReceived - sample.lastBytes) / elapsed))
            sample.smoothedSpeed = Int64(0.3 * Double(instant) + 0.7 * Double(sample.smoothedSpeed))
            sample.lastBytes = item.bytesReceived
            sample.lastTime = now
            speedSamples[key] = sample
        } else {
            speedSamples[key] = SpeedSample(lastBytes: item.bytesReceived, lastTime: now, smoothedSpeed: 0)
        }
    }

    func augmentedBridgeData(for item: DownloadItem) -> [String: Any] {
        var data = item.bridgeData
        guard let key = item.key, let sample = speedSamples[key], sample.smoothedSpeed > 0 else { return data }
        data["speedBytesPerSec"] = sample.smoothedSpeed
        if item.totalBytes > 0 {
            let remaining = item.totalBytes - item.bytesReceived
            data["eta"] = max(0.0, Double(remaining) / Double(sample.smoothedSpeed))
        }
        return data
    }

    private func sendDownloadNotification(for item: DownloadItem) {
        guard item.state == .complete || item.state == .interrupted, !item.fileMissing,
              !(item.key.map { pendingAutoResumes.contains($0) } ?? false) else { return }
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

        let identifier = "download-\(item.profileId?.uuidString ?? "")-\(item.id ?? 0)-\(item.state.rawValue)"
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
