import Foundation
import WebKit
import os

/// Keeps one profile's extension workers reachable: an idle worker unloads and is reconnected or restarted on its next event, a user
/// action gets a running worker, and a worker WebKit wrongly believes loaded is restarted in place, keeping its session state.
@MainActor
final class BackgroundSupervisor {
    private static let logger = Logger(liloCategory: "background-supervisor")

    struct Health {
        /// Set at load time when WK-compat preparation failed; a revive must never clear it.
        var prepDegraded = false
        /// Set when a revive is attempted, cleared only when that reload succeeds.
        var runtimeDegraded = false
        var lastReviveAttempt: Date?
        var lastRestartAttempt: Date?
        /// Restarts since the worker last connected; each one doubles the wait before the next.
        var restartFailures = 0
        /// Set when every revive failed; the action and commands cannot reach the worker. Cleared by
        /// the next successful load or connection.
        var failed = false
        var failureReason: String?
        var lastErrorCount = 0
        /// A closed backing view can still address the process WebKit reuses for the next worker (WebKit gap 103).
        var workerWebView: WKWebView?
        /// The view's PID accessor reports zero once WebKit closes it.
        var workerPid: Int?
        var workerInstance: String?

        var bridgeStatus: String {
            (prepDegraded || runtimeDegraded || failed) ? "degraded" : "loaded"
        }
    }

    /// Long enough for a heavy worker's boot, short enough that a load that never resolves cannot block
    /// reloads forever.
    static let loadTimeout: TimeInterval = 10
    /// At most one revive per extension in this window, so the error a failed revive emits cannot spin a
    /// second attempt.
    static let reviveDebounce: TimeInterval = 10
    /// Automatic restarts stop after this many in a row without the worker connecting; the extension
    /// then shows as failed until a user action or a connection revives it.
    static let maxRestarts = 5

    private var health: [String: Health] = [:]
    /// When each extension's background load started, cleared when it resolves. Unloading a context
    /// mid-evaluation segfaults the worker process, so nothing may restart a loading background. Kept
    /// apart from `health`: it must survive the unload and load of a full reload.
    private var loadStartedAt: [String: Date] = [:]
    /// Events arriving together share the load, channel wait and recovery, not just the initial load.
    private var responding: [String: Task<Void, Never>] = [:]

    private let context: (String) -> WKWebExtensionContext?
    /// The worker's channel, as the extension's lifecycle tracks it.
    private let worker: (String) -> ExtensionLifecycle.Worker?
    private let ready: (String) -> Bool
    /// Unloads and reloads the extension from disk: its session state is lost.
    private let reload: (String) async -> Void
    /// A change the extensions panel shows.
    private let didChange: (String) -> Void

    init(
        context: @escaping (String) -> WKWebExtensionContext?,
        worker: @escaping (String) -> ExtensionLifecycle.Worker?,
        ready: @escaping (String) -> Bool,
        reload: @escaping (String) async -> Void,
        didChange: @escaping (String) -> Void
    ) {
        self.context = context
        self.worker = worker
        self.ready = ready
        self.reload = reload
        self.didChange = didChange
    }

    // MARK: - Lifecycle

    func started(_ extensionId: String, preparationDegraded: Bool) {
        health[extensionId] = Health(prepDegraded: preparationDegraded)
        if preparationDegraded { didChange(extensionId) }
    }

    func stopped(_ extensionId: String) {
        health[extensionId] = nil
        responding.removeValue(forKey: extensionId)?.cancel()
    }

    func health(for extensionId: String) -> Health? {
        health[extensionId]
    }

    // MARK: - Loading

    /// A load older than the timeout counts as abandoned.
    func isLoadInFlight(_ extensionId: String) -> Bool {
        loadStartedAt[extensionId].map { Date().timeIntervalSince($0) < Self.loadTimeout } ?? false
    }

    /// The one place that awaits WebKit's background load, so every caller marks the extension as
    /// loading for the whole evaluation of the worker script. WebKit never answers for a worker whose
    /// load hangs, so the wait is bounded: a timeout counts as a failure.
    @discardableResult
    func load(_ extensionId: String) async -> Bool {
        guard let context = context(extensionId), context.webExtension.hasBackgroundContent else { return false }
        let started = Date()
        loadStartedAt[extensionId] = started
        defer { if loadStartedAt[extensionId] == started { loadStartedAt[extensionId] = nil } }
        // Ends when the worker connects (`workerChannel`); a running worker's load starts nothing.
        let startsWorker = worker(extensionId) != .running
        if startsWorker {
            _ = PerfSignposts.extensions.beginInterval("workerStart", id: PerfSignposts.extensions.makeSignpostID(from: context), "\(extensionId)")
        }
        var timeout: Task<Void, Never>?
        let failure: String? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (String?) -> Void = { failure in
                guard resumed.withLock({ wasResumed in defer { wasResumed = true }; return !wasResumed }) else { return }
                continuation.resume(returning: failure)
            }
            context.loadBackgroundContent { error in
                finish(error.map { ExtensionDiagnostics.diagnosticDescription(for: $0) })
            }
            timeout = Task {
                guard (try? await Task.sleep(for: .seconds(Self.loadTimeout))) != nil else { return }
                finish("no answer after \(Int(Self.loadTimeout))s")
            }
        }
        timeout?.cancel()
        if let failure {
            if startsWorker {
                PerfSignposts.extensions.endInterval("workerStart", id: PerfSignposts.extensions.makeSignpostID(from: context), "failed")
            }
            Self.logger.error("loadBackgroundContent failed for \(extensionId, privacy: .public): \(failure, privacy: .public)")
            health[extensionId]?.failureReason = failure
            return false
        }
        setFlag(\.failed, to: false, for: extensionId)
        return true
    }

    // MARK: - Liveness

    /// The worker opened, idly closed or lost its channel to Lilo. Only a lost channel means it stopped:
    /// a restart after an unload would kill the next load's worker.
    func workerChannel(_ extensionId: String, _ channel: GapEvents.WorkerChannel, instance: String?) {
        guard health[extensionId] != nil else { return }
        switch channel {
        case .open:
            if let context = context(extensionId) {
                // An idle port can reconnect from the old process after WebKit replaced its backing page.
                if health[extensionId]?.workerWebView == nil || health[extensionId]?.workerInstance != instance {
                    let webView = Self.backgroundWebView(of: context)
                    health[extensionId]?.workerWebView = webView
                    let pid = webView.flatMap { WebViewPrivateAccessors($0).pid("_webProcessIdentifier") }
                    health[extensionId]?.workerPid = pid
                    Self.logger.debug("background worker connected for \(extensionId, privacy: .public) process=\(pid ?? 0, privacy: .public)")
                    health[extensionId]?.workerInstance = instance
                }
                PerfSignposts.extensions.endInterval("workerStart", id: PerfSignposts.extensions.makeSignpostID(from: context), "\(extensionId)")
            }
            health[extensionId]?.restartFailures = 0
            setFlag(\.failed, to: false, for: extensionId)
        case .idle, .unloaded:
            break
        case .lost:
            restartIfStopped(extensionId)
        }
    }

    /// A gap event for a worker without its channel: it receives the event once it connects, and
    /// nothing else would make it. A running worker is told to reconnect, a stopped one is started.
    func wake(_ extensionId: String) {
        guard health[extensionId] != nil,
              context(extensionId)?.webExtension.hasBackgroundContent == true,
              !isLoadInFlight(extensionId) else { return }
        PerfSignposts.energy.emitEvent("workerWake", "\(extensionId)")
        Task { @MainActor [weak self] in
            guard let self, !self.isLoadInFlight(extensionId) else { return }
            await self.ensureResponsive(extensionId)
        }
    }

    /// Asks a running worker that let its channel go to open it again (ipc.ts).
    private func nudge(_ extensionId: String) {
        // Only an idle one: the broadcast reaches every worker of the origin, and a previous load's, still
        // stopping, would take the events meant for the new one.
        guard worker(extensionId) == .idle, let context = context(extensionId),
              let webView = Self.backgroundWebView(of: context) else { return }
        // The background page shares the worker's origin, so the broadcast reaches the worker.
        webView.evaluateJavaScript("new BroadcastChannel('lilo-reconnect').postMessage(0)")
    }

    /// Guarantees a running worker before a user action (popup, command). `loadBackgroundContent()` is a no-op on a context WebKit
    /// reports loaded, so a silent worker is restarted, and one that fails to load is restarted once, then marked failed.
    func ensureResponsive(_ extensionId: String) async {
        guard let context = context(extensionId), context.webExtension.hasBackgroundContent else { return }
        if let task = responding[extensionId] {
            await task.value
            await finishStartup(extensionId)
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.makeResponsive(extensionId)
        }
        responding[extensionId] = task
        await task.value
        // A restart only waits for WebKit's load; the replacement worker must finish the bridge barrier too.
        // This caller survives an internal full reload, which cancels the old context's recovery task.
        await finishStartup(extensionId)
        if self.context(extensionId) === context { responding[extensionId] = nil }
    }

    private func finishStartup(_ extensionId: String) async {
        guard let context = context(extensionId), health[extensionId]?.prepDegraded == false else { return }
        for _ in 0..<20 {
            guard !Task.isCancelled, self.context(extensionId) === context else { return }
            if ready(extensionId) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // A connected worker that is only slow to settle its startup reads still answers: only silence is a failure.
        if self.context(extensionId) === context, worker(extensionId) != .running { markFailed(extensionId) }
    }

    private func makeResponsive(_ extensionId: String) async {
        // An existing load must finish its startup barrier too, but may never be restarted here:
        // that could tear the context down mid-evaluation.
        let wasLoading = isLoadInFlight(extensionId)
        let loaded = await load(extensionId)
        guard !Task.isCancelled else { return }
        guard loaded else {
            guard !wasLoading else { return }
            let restarted = await restart(extensionId)
            if !Task.isCancelled, !restarted { markFailed(extensionId) }
            return
        }
        guard let health = health[extensionId],
              // A prep-degraded worker may run without the prelude that connects: its silence proves nothing.
              !health.prepDegraded, !ready(extensionId)
        else { return }
        // An unloaded worker comes back through the plain load and connects from its prelude at once; a
        // running one that let its channel go opens it again when nudged.
        nudge(extensionId)
        for _ in 0..<20 {
            guard !Task.isCancelled else { return }
            if ready(extensionId) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // A connected worker still settling its startup reads is slow, not broken: restarting it would loop.
        guard !Task.isCancelled, !wasLoading, worker(extensionId) != .running else { return }
        let restarted = await restart(extensionId)
        // The reload's unload cancels this task; the reload itself must not inherit that cancellation.
        if !Task.isCancelled, !restarted { await Task { await self.fullReload(extensionId) }.value }
    }

    /// A lost channel means the worker stopped. An idle unload is left alone (WebKit relaunches it on its next event; restarting would
    /// keep every worker alive); only a worker WebKit still believes loaded, which nothing would start again, is restarted.
    func restartIfStopped(_ extensionId: String) {
        guard let health = health[extensionId], !health.failed, !isLoadInFlight(extensionId), responding[extensionId] == nil,
              // The revive debounce, doubled per restart after which the worker never connected.
              Self.shouldAttempt(lastAttempt: health.lastRestartAttempt, now: Date(), debounce: Self.reviveDebounce * pow(2, Double(health.restartFailures)))
        else { return }
        self.health[extensionId]?.lastRestartAttempt = Date()
        Task { @MainActor [weak self] in
            // WebKit tears the background web view down right after the worker's scope closes.
            try? await Task.sleep(for: .seconds(1))
            // A worker that connected meanwhile runs.
            guard let self, let context = self.context(extensionId), Self.backgroundWebView(of: context) != nil,
                  !self.isLoadInFlight(extensionId), self.responding[extensionId] == nil,
                  self.health[extensionId] != nil, self.worker(extensionId) != .running else { return }
            self.health[extensionId]?.restartFailures += 1
            let failures = self.health[extensionId]?.restartFailures ?? 0
            guard failures <= Self.maxRestarts else {
                self.markFailed(extensionId)
                return
            }
            Self.logger.notice("background worker stopped for \(extensionId, privacy: .public); restart \(failures) in place")
            await self.restart(extensionId)
        }
    }

    /// A running worker starts over from its files, keeping its session state; a stopped one reads
    /// them when it next starts anyway.
    func restartIfRunning(_ extensionId: String) async {
        guard !isLoadInFlight(extensionId) else { return }
        await responding[extensionId]?.value
        guard !isLoadInFlight(extensionId) else { return }
        await restart(extensionId)
    }

    // MARK: - Errors

    /// Never attempted always permits an attempt.
    static func shouldAttempt(lastAttempt: Date?, now: Date, debounce: TimeInterval) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= debounce
    }

    /// The context's errors changed: a background that newly failed to load gets one debounced revive.
    func contextErrorsChanged(_ extensionId: String) {
        guard let context = context(extensionId), let previousCount = health[extensionId]?.lastErrorCount else { return }
        let errors = context.errors
        // `errors` is cumulative; a shorter list was reset, so all of it is new.
        let newErrors = errors.dropFirst(previousCount <= errors.count ? previousCount : 0)
        ExtensionDiagnostics.logContextErrorsIfNeeded(newErrors, of: context, extensionId: extensionId, reason: "notification", logger: Self.logger)
        health[extensionId]?.lastErrorCount = errors.count
        didChange(extensionId)
        guard context.webExtension.hasBackgroundContent,
              ExtensionDiagnostics.errorsWarrantBackgroundRevive(newErrors) else { return }
        // The debounce in `reviveIfNeeded` is the guard against the error a failed reload emits.
        Task { @MainActor [weak self] in await self?.reviveIfNeeded(extensionId) }
    }

    /// One debounced attempt to reload a background. The attempt is timestamped BEFORE loading so the
    /// error the reload itself emits lands inside the window and cannot spawn a second attempt.
    @discardableResult
    func reviveIfNeeded(_ extensionId: String) async -> Bool {
        guard context(extensionId)?.webExtension.hasBackgroundContent == true,
              // Touching a background on its way up would race the running evaluation of its worker script.
              !isLoadInFlight(extensionId), responding[extensionId] == nil,
              Self.shouldAttempt(lastAttempt: health[extensionId]?.lastReviveAttempt, now: Date(), debounce: Self.reviveDebounce)
        else { return false }
        health[extensionId]?.lastReviveAttempt = Date()
        Self.logger.notice("background revive after a load failure for \(extensionId, privacy: .public)")
        // Degrade before loading, clear only on success: `loadBackgroundContent()` never resolves for a
        // worker that throws at top level, so nothing below would run and the state would read "loaded".
        setFlag(\.runtimeDegraded, to: true, for: extensionId)
        guard await load(extensionId) else { return false }
        // Leaves a sticky preparation degradation set, so a broken-on-disk extension is never reported healthy.
        setFlag(\.runtimeDegraded, to: false, for: extensionId)
        return true
    }

    /// WebKit supplied no popover: the degraded indicator keeps the click from failing silently.
    func markPopupUnavailable(_ extensionId: String) {
        setFlag(\.runtimeDegraded, to: true, for: extensionId)
    }

    func clearErrorCounts() {
        for id in health.keys { health[id]?.lastErrorCount = 0 }
    }

    // MARK: - Restarts

    static func backgroundWebView(of context: WKWebExtensionContext) -> WKWebView? {
        let selector = NSSelectorFromString("_backgroundWebView")
        guard context.responds(to: selector) else { return nil }
        return context.perform(selector)?.takeUnretainedValue() as? WKWebView
    }

    static func terminateProcess(_ webView: WKWebView) {
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        if webView.responds(to: kill) { webView.perform(kill) }
    }

    /// Returns once `pid` has exited, or after a second: until WebKit sees a killed worker process exit, it can
    /// start the extension's next worker in it, where that worker never runs (WebKit gap 103).
    static func processExit(_ pid: Int) async {
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source.setEventHandler { source.cancel() }
            source.setCancelHandler { continuation.resume() }
            source.resume()
            // A process gone before the source registered sends no event.
            if kill(pid_t(pid), 0) != 0, errno == ESRCH { source.cancel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { source.cancel() }
        }
    }

    /// Starts a fresh worker in the same context by killing the background web view's process, the one signal that makes WebKit drop it;
    /// `storage.session` survives, so a password manager stays unlocked. False without a background web view or the SPI.
    @discardableResult
    private func restart(_ extensionId: String) async -> Bool {
        guard let context = context(extensionId), let webView = Self.backgroundWebView(of: context),
              webView.responds(to: NSSelectorFromString("_killWebContentProcessAndResetState")) else { return false }
        Self.logger.notice("background restart in place for \(extensionId, privacy: .public)")
        let started = Date()
        loadStartedAt[extensionId] = started
        defer { if loadStartedAt[extensionId] == started { loadStartedAt[extensionId] = nil } }
        // The current backing page may be in a new process while the worker is still in the previous one's.
        let previous = health[extensionId]
        Self.terminateProcess(webView)
        if let view = previous?.workerWebView, view !== webView {
            Self.terminateProcess(view)
            if let pid = previous?.workerPid { await Self.processExit(pid) }
        }
        var waits = 0
        while Self.backgroundWebView(of: context) != nil, waits < 20 {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
            waits += 1
        }
        guard !Task.isCancelled, self.context(extensionId) === context else { return false }
        return await load(extensionId)
    }

    /// Only for a background `restart` cannot reach: the reload drops the context's state, so a
    /// password manager re-locks.
    private func fullReload(_ extensionId: String) async {
        Self.logger.notice("background full reload for \(extensionId, privacy: .public); its session state is lost")
        // Claim the load guard across the swap so nothing drives the old context while it is torn down.
        loadStartedAt[extensionId] = Date()
        defer { loadStartedAt[extensionId] = nil }
        await reload(extensionId)
    }

    private func markFailed(_ extensionId: String) {
        Self.logger.error("background of \(extensionId, privacy: .public) failed: \(self.health[extensionId]?.failureReason ?? "no worker", privacy: .public)")
        setFlag(\.failed, to: true, for: extensionId)
    }

    private func setFlag(_ flag: WritableKeyPath<Health, Bool>, to value: Bool, for extensionId: String) {
        guard let current = health[extensionId], current[keyPath: flag] != value else { return }
        health[extensionId]?[keyPath: flag] = value
        didChange(extensionId)
    }
}
