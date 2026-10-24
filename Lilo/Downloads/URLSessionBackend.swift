import Foundation

/// Handles extension-initiated downloads via URLSession (supports native pause/resume).
@MainActor
final class URLSessionBackend: NSObject {
    var downloadsFolderProvider: () -> URL? = { nil }
    var store: DownloadStore? {
        get { flight.store }
        set { flight.store = newValue }
    }
    var onUpdated: ((DownloadItem) -> Void)? {
        get { flight.onUpdated }
        set { flight.onUpdated = newValue }
    }

    /// Keeps this backend as its delegate until the app quits: a URLSession retains its delegate.
    private var _session: URLSession?
    private var session: URLSession {
        if let existing = _session { return existing }
        let config = URLSessionConfiguration.default; config.timeoutIntervalForRequest = 30
        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = newSession; return newSession
    }

    /// Maps URLSessionDownloadTask.taskIdentifier to the task and its DownloadItem.id. Holding the
    /// task itself keeps pause/cancel synchronous: looking it up through `session.tasks` would cost
    /// an async round trip per download, paid N times on the quit path.
    private var activeTasks: [Int: (task: URLSessionDownloadTask, id: Int64)] = [:]

    private let flight = InFlightDownloads()

    /// Per-task state the URLSession delegate queue needs without hopping to the main actor.
    private final class TaskRecord: Sendable {
        /// Leading-edge progress throttle, checked on the delegate queue before the main-actor hop:
        /// didWriteData fires per network chunk (hundreds/sec), enough to flood the chrome bridge.
        let gate = ProgressEmitGate()
        /// Where didFinishDownloadingTo moves the temp file, which it must do before it returns.
        let destination: URL
        /// Set for a destination the caller chose (an overwrite, a save panel): a file there is replaced.
        let replacesExisting: Bool

        init(destination: URL, replacesExisting: Bool = false) {
            self.destination = destination
            self.replacesExisting = replacesExisting
        }
    }

    /// Touched from both the main actor (task setup/teardown) and URLSession's delegate queue, so
    /// access is serialized with a lock rather than actor isolation.
    private nonisolated(unsafe) var taskRecords: [Int: TaskRecord] = [:]
    private let taskRecordsLock = NSLock()
    private nonisolated static let progressInterval: TimeInterval = 0.2

    private func registerRecord(for taskId: Int, destination: URL, replacesExisting: Bool = false) {
        taskRecordsLock.lock(); defer { taskRecordsLock.unlock() }
        taskRecords[taskId] = TaskRecord(destination: destination, replacesExisting: replacesExisting)
    }

    private func removeRecord(for taskId: Int) {
        taskRecordsLock.lock(); defer { taskRecordsLock.unlock() }
        taskRecords.removeValue(forKey: taskId)
    }

    private nonisolated func record(for taskId: Int) -> TaskRecord? {
        taskRecordsLock.lock(); defer { taskRecordsLock.unlock() }
        return taskRecords[taskId]
    }

    /// Start a new download from a URL (called by chrome.downloads.download()).
    /// Returns the DownloadItem.id assigned. A given `destination` is used as is, replacing any file there
    /// once the download completes; otherwise the name is made unique in the downloads folder.
    @discardableResult
    func startDownload(request: URLRequest, suggestedFilename: String, destination: URL? = nil) throws -> Int64 {
        let finalURL = destination ?? WKBackend.resolveDestination(for: suggestedFilename, in: resolvedDownloadsFolder(downloadsFolderProvider()))

        var item = DownloadItem(
            id: nil,
            url: request.url?.absoluteString ?? "",
            filename: finalURL.lastPathComponent,
            destinationPath: finalURL.path,
            bytesReceived: 0,
            totalBytes: -1,
            state: .inProgress,
            startedAt: Date(),
            fileMissing: false
        )
        item.source = "url"
        try store?.insert(&item)
        guard let id = item.id else { throw NSError(domain: "URLSessionBackend", code: 1) }

        let task = session.downloadTask(with: request)
        activeTasks[task.taskIdentifier] = (task, id)
        registerRecord(for: task.taskIdentifier, destination: finalURL, replacesExisting: destination != nil)
        flight.begin(id, item)
        task.resume()
        return id
    }

    /// Returns only after the paused state (with resumeData) is persisted, so the quit path
    /// can rely on the row surviving the process.
    func pause(id: Int64) async {
        guard let entry = activeTasks.first(where: { $0.value.id == id }) else { return }
        // The task stays registered across the await so a finish already queued still moves the
        // file and settles complete; the guard below then adopts that completion.
        let data: Data? = await withCheckedContinuation { cont in
            entry.value.task.cancel(byProducingResumeData: { cont.resume(returning: $0) })
        }
        flight.settle(id) { item in
            guard item.state == .inProgress else { return false }
            item.resumeData = data
            item.state = .paused
            return true
        }
        activeTasks.removeValue(forKey: entry.key)
        removeRecord(for: entry.key)
    }

    /// Resumes a paused download, or an interrupted one that still carries resumeData (retry).
    func resume(id: Int64) throws {
        guard var item = try store?.fetch(id: id),
              item.state == .paused || item.state == .interrupted,
              let resumeData = item.resumeData else { return }
        item.resumeData = nil
        item.state = .inProgress
        item.error = nil
        item.endedAt = nil
        // The row first: a failed write leaves no task tracked that nothing would ever start.
        try store?.update(item)
        let task = session.downloadTask(withResumeData: resumeData)
        activeTasks[task.taskIdentifier] = (task, id)
        registerRecord(for: task.taskIdentifier, destination: URL(fileURLWithPath: item.destinationPath))
        flight.begin(id, item)
        task.resume()
    }

    func cancel(id: Int64) {
        guard let entry = activeTasks.first(where: { $0.value.id == id }) else { return }
        entry.value.task.cancel(); activeTasks.removeValue(forKey: entry.key); removeRecord(for: entry.key)
        flight.settle(id) { item in
            item.state = .interrupted; item.error = "Cancelled by user"; item.endedAt = Date()
            return true
        }
    }

    func isTracking(id: Int64) -> Bool {
        activeTasks.contains { $0.value.id == id }
    }

    var trackedIds: [Int64] { activeTasks.values.map(\.id) }
}

extension URLSessionBackend: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        guard let record = record(for: taskId), record.gate.pass(interval: Self.progressInterval) else { return }
        Task { @MainActor in
            guard let id = activeTasks[taskId]?.id else { return }
            flight.tick(id, bytesReceived: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes the temp file as soon as this returns, so the move happens here rather
        // than after a hop to the main actor. It also keeps a cross-volume move (downloads folder on
        // another disk, so a full copy) off the main thread.
        let taskId = downloadTask.taskIdentifier
        guard let record = record(for: taskId) else { return }
        var destination = record.destination
        var failure: String?
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            // The body is the server's error page: leave it to URLSession's temp-file cleanup.
            failure = "Server error (HTTP \(status))"
        } else {
            do {
                if !record.replacesExisting {
                    // Another download may have taken the name since this one started.
                    destination = WKBackend.resolveDestination(
                        for: destination.lastPathComponent, in: destination.deletingLastPathComponent()
                    )
                }
                if record.replacesExisting, FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
                } else {
                    try FileManager.default.moveItem(at: location, to: destination)
                }
            } catch {
                failure = error.localizedDescription
            }
        }

        let finalDestination = destination
        let finalFailure = failure
        Task { @MainActor in
            guard let id = activeTasks[taskId]?.id else { return }
            let settled = flight.settle(id) { item in
                if let finalFailure {
                    item.state = .interrupted; item.error = finalFailure
                } else {
                    item.destinationPath = finalDestination.path
                    item.filename = finalDestination.lastPathComponent
                    DownloadQuarantine.stamp(path: item.destinationPath, source: item.url)
                    item.state = .complete
                }
                item.endedAt = Date()
                return true
            }
            guard settled != nil else { return }
            activeTasks.removeValue(forKey: taskId)
            removeRecord(for: taskId)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // pause and cancel settle the cancellations they cause themselves.
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        let taskId = task.taskIdentifier
        Task { @MainActor in
            guard let id = activeTasks[taskId]?.id else { return }
            let settled = flight.settle(id) { item in
                // If we already marked complete in didFinishDownloadingTo, skip
                guard item.state == .inProgress else { return false }
                item.state = .interrupted
                item.error = error.localizedDescription
                item.endedAt = Date()
                if let urlError = error as? URLError,
                   let data = urlError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    item.resumeData = data
                }
                return true
            }
            guard settled != nil else { return }
            activeTasks.removeValue(forKey: taskId)
            removeRecord(for: taskId)
        }
    }
}
