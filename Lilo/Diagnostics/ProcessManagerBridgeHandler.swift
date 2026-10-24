import Darwin
import Foundation

@MainActor
final class ProcessManagerBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = [
        "getProcessSnapshot",
        "getTabMemory",
        "focusProcessTab",
        "reloadProcessTab",
        "closeProcessTab",
        "terminateProcess",
        "sleepHiddenTabs"
    ]

    private weak var browserStateStore: BrowserStateStore?
    private weak var tabManager: TabManager?
    private weak var windowController: MainWindowController?
    private weak var bridgeRouter: BridgeRouter?
    private let metricsSampler = MetricsSampler()
    /// Last memory and CPU reading of each hovered tab, so the next one measures CPU since then.
    private var tabUsageSamples: [UUID: (resident: UInt64, cpu: UInt64, time: UInt64)] = [:]
    private let killProcess: (Int32) -> Int32
    private let identityDiagnostics: @MainActor (WKWebViewTab) -> WebViewProcessDiagnostics

    init(
        browserStateStore: BrowserStateStore,
        tabManager: TabManager,
        windowController: MainWindowController,
        bridgeRouter: BridgeRouter,
        killProcess: @escaping (Int32) -> Int32 = { kill($0, SIGTERM) },
        identityDiagnostics: @escaping @MainActor (WKWebViewTab) -> WebViewProcessDiagnostics = { engine in
            // Pid-only reflection: enough to key processes for id/pid/kind resolution without the
            // full per-webview diagnostics sweep.
            let accessors = WebViewPrivateAccessors(engine.wkWebView)
            return WebViewProcessDiagnostics(
                webProcessIdentifier: accessors.pid("_webProcessIdentifier"),
                provisionalWebProcessIdentifier: accessors.pid("_provisionalWebProcessIdentifier"),
                networkProcessIdentifier: accessors.pid("_networkProcessIdentifier"),
                gpuProcessIdentifier: accessors.pid("_gpuProcessIdentifier"),
                modelProcessIdentifier: accessors.pid("_modelProcessIdentifier")
            )
        }
    ) {
        self.browserStateStore = browserStateStore
        self.tabManager = tabManager
        self.windowController = windowController
        self.bridgeRouter = bridgeRouter
        self.killProcess = killProcess
        self.identityDiagnostics = identityDiagnostics
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {
        case "getProcessSnapshot":
            publishSnapshot()

        case "getTabMemory":
            if let tabId = message.uuid("tabId") { await publishTabUsage(tabId) }

        case "focusProcessTab":
            focusTab(message)

        case "reloadProcessTab":
            reloadTab(message)

        case "closeProcessTab":
            closeTab(message)

        case "terminateProcess":
            terminateProcess(message)

        case "sleepHiddenTabs":
            windowController?.sleepHiddenTabs()
            publishSnapshotSoon()

        default:
            break
        }

        return nil
    }

    /// Memory and CPU of what a tab runs, for its hover popup: a web tab's content process (shared
    /// evenly when several tabs use it), or every process of a terminal's shell session.
    private func publishTabUsage(_ tabId: UUID) async {
        let pids: [Int]
        let sharing: Int
        if let shell = tabManager?.terminalHost.view(for: tabId)?.session.pid, shell > 0 {
            // forkpty made the shell a session leader: the commands it runs share its session.
            let count = Int(proc_listallpids(nil, 0))
            var all = [pid_t](repeating: 0, count: count + 64)
            let listed = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size)))
            pids = all.prefix(max(0, listed)).filter { $0 > 0 && getsid($0) == shell }.map(Int.init)
            sharing = 1
        } else if let process = browserStateStore?.webContentProcess(forTab: tabId) {
            (pids, sharing) = ([process.pid], process.sharing)
        } else {
            return
        }
        func sample() -> (resident: UInt64, cpu: UInt64, time: UInt64) {
            let infos = pids.compactMap(ProcessTaskInfoSampler.taskInfo(pid:))
            return (infos.reduce(0) { $0 + $1.pti_resident_size }, infos.reduce(0) { $0 + ProcessTaskInfoSampler.cpuNanoseconds($1) }, DispatchTime.now().uptimeNanoseconds)
        }
        // CPU is a rate: a hover just started measures over a short window right away.
        var previous = tabUsageSamples[tabId]
        if previous.map({ DispatchTime.now().uptimeNanoseconds - $0.time > 10_000_000_000 }) ?? true {
            previous = sample()
            try? await Task.sleep(for: .milliseconds(200))
        }
        let current = sample()
        // A reading older than the measuring window is never reused: closed and long-unhovered tabs drop out.
        tabUsageSamples = tabUsageSamples.filter { current.time - $0.value.time <= 10_000_000_000 }
        tabUsageSamples[tabId] = current
        guard current.resident > 0 else { return }
        var data: [String: Any] = ["tabId": tabId.uuidString, "bytes": Double(current.resident / UInt64(max(sharing, 1)))]
        // Processes that ended in between take their time with them; that window has no reading.
        if let previous, current.cpu >= previous.cpu, current.time > previous.time {
            data["cpuPercent"] = Double(current.cpu - previous.cpu) / Double(current.time - previous.time) * 100 / Double(max(sharing, 1))
        }
        bridgeRouter?.send(event: "tabMemoryUpdated", data: data)
    }

    private func publishSnapshot() {
        guard let browserStateStore else { return }
        let processes = browserStateStore.processSnapshot(metricsProvider: metricsSampler.metrics(for:))
        bridgeRouter?.send(event: "processSnapshotUpdated", data: ["processes": processes.map(\.bridgeData)])
    }

    private func publishSnapshotSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.publishSnapshot()
        }
    }

    private func tabAndSpace(_ message: BridgeMessage) -> (tabId: UUID, spaceId: UUID)? {
        guard let tabId = message.uuid("tabId"), let spaceId = message.uuid("spaceId") else {
            bridgeRouter?.sendActionCompleted("processManagerActionCompleted", action: message.action, message: "Missing tab identifier".localized, level: "error")
            return nil
        }
        return (tabId, spaceId)
    }

    private func liveEngine(tabId: UUID, spaceId: UUID) -> WKWebViewTab? {
        browserStateStore?.engine(tabId: tabId, spaceId: spaceId) ?? tabManager?.engineTab(for: tabId)
    }

    private func focusTab(_ message: BridgeMessage) {
        guard let (tabId, spaceId) = tabAndSpace(message) else { return }
        if tabManager?.currentSpaceId != spaceId {
            windowController?.switchToSpace(spaceId)
        }
        windowController?.activateTabStateFirst(id: tabId)
        publishSnapshotSoon()
    }

    private func reloadTab(_ message: BridgeMessage) {
        guard let (tabId, spaceId) = tabAndSpace(message) else { return }
        guard let engine = liveEngine(tabId: tabId, spaceId: spaceId) else {
            bridgeRouter?.sendActionCompleted("processManagerActionCompleted", action: message.action, message: "No live WebView for this tab".localized, level: "error")
            return
        }

        engine.reload()
        bridgeRouter?.sendActionCompleted("processManagerActionCompleted", action: message.action, message: "Tab reloaded".localized)
        publishSnapshotSoon()
    }

    private func closeTab(_ message: BridgeMessage) {
        guard let (tabId, spaceId) = tabAndSpace(message) else { return }
        if tabManager?.currentSpaceId != spaceId {
            windowController?.switchToSpace(spaceId)
        }
        windowController?.closeTabStateFirst(id: tabId)
        bridgeRouter?.sendActionCompleted("processManagerActionCompleted", action: message.action, message: "Tab closed".localized)
        publishSnapshotSoon()
    }

    private func terminateProcess(_ message: BridgeMessage) {
        guard message.bool("confirmed") else {
            bridgeRouter?.sendActionCompleted("processManagerActionCompleted", action: message.action, message: "Termination was not confirmed".localized, level: "error")
            return
        }
        guard let process = resolveProcess(message) else {
            bridgeRouter?.sendActionCompleted("processManagerActionCompleted", action: message.action, message: "Process no longer exists".localized, level: "error")
            publishSnapshot()
            return
        }
        guard process.pid != Int(getpid()) else {
            bridgeRouter?.sendActionCompleted("processManagerActionCompleted", action: message.action, message: "Refusing to terminate the app process".localized, level: "error")
            return
        }

        if killProcess(Int32(process.pid)) == 0 {
            bridgeRouter?.sendActionCompleted("processManagerActionCompleted", action: message.action, message: String(format: "Termination requested for PID %@".localized, String(process.pid)))
            publishSnapshotSoon()
        } else {
            bridgeRouter?.sendActionCompleted(
                "processManagerActionCompleted",
                action: message.action,
                message: String(format: "Unable to terminate PID %@: %@".localized, String(process.pid), String(cString: strerror(errno))),
                level: "error"
            )
            publishSnapshot()
        }
    }

    private func resolveProcess(_ message: BridgeMessage) -> BrowserProcessInfo? {
        // Resolution reads only id/pid/kind/tabs, so skip the full diagnostics sweep.
        guard let processId = message.string("processId"),
              let processes = browserStateStore?.processSnapshot(diagnosticsProvider: identityDiagnostics) else { return nil }
        return processes.first { $0.id == processId }
    }
}

private extension ProcessManagerBridgeHandler {
    final class MetricsSampler {
        private struct Sample {
            var uptimeNanoseconds: UInt64
            var cpuNanoseconds: UInt64
        }

        private var previousSamples: [Int: Sample] = [:]

        func metrics(for pids: Set<Int>) -> [Int: ProcessResourceMetrics] {
            let now = DispatchTime.now().uptimeNanoseconds
            var result: [Int: ProcessResourceMetrics] = [:]
            var nextSamples: [Int: Sample] = [:]

            for pid in pids where pid > 0 {
                guard let task = ProcessTaskInfoSampler.taskInfo(pid: pid) else { continue }
                let cpuNanoseconds = ProcessTaskInfoSampler.cpuNanoseconds(task)
                let sample = Sample(uptimeNanoseconds: now, cpuNanoseconds: cpuNanoseconds)
                let cpuPercent: Double?
                if let previous = previousSamples[pid],
                   now > previous.uptimeNanoseconds,
                   cpuNanoseconds >= previous.cpuNanoseconds {
                    cpuPercent = Double(cpuNanoseconds - previous.cpuNanoseconds)
                        / Double(now - previous.uptimeNanoseconds)
                        * 100
                } else {
                    cpuPercent = nil
                }

                result[pid] = ProcessResourceMetrics(residentSizeBytes: task.pti_resident_size, cpuPercent: cpuPercent)
                nextSamples[pid] = sample
            }

            previousSamples = nextSamples
            return result
        }
    }
}
