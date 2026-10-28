import AppKit
import Darwin
import QuartzCore
import Synchronization

/// Records a performance session on demand (Help > Diagnostics): signposts, main-thread hangs,
/// dropped frames, menu actions and per-process CPU, memory, wakeups, disk and energy, written as a
/// Chrome Trace Event file that ui.perfetto.dev opens. Nothing runs outside a recording.
@MainActor
enum PerfRecorder {
    enum Kind: UInt8, Sendable { case begin, end, event }

    struct Process: Sendable, Equatable {
        let pid: Int32
        /// What the process runs: `lilo`, `chrome`, `tab`, `extension`, `network`, `gpu`...
        let role: String
    }

    struct Event: Sendable {
        let kind: Kind
        let category: StaticString
        let name: StaticString
        let id: UInt64
        let uptime: UInt64
        let detail: String
        let isMainThread: Bool
    }

    struct Sample: Sendable {
        let process: Process
        let uptime: UInt64
        let cpuPercent: Double
        let footprintBytes: UInt64
        let wakeupsPerSecond: Double
        let diskReadBytesPerSecond: Double
        let diskWriteBytesPerSecond: Double
        let milliwatts: Double
    }

    private struct Buffer: Sendable {
        var events: [Event] = []
        var samples: [Sample] = []
        var droppedEvents = 0
    }

    static let maxDuration: Duration = .seconds(600)
    nonisolated static let hangThreshold: UInt64 = 100_000_000
    /// About 25 MB of events: a busy 10-minute session stays well under it.
    nonisolated private static let eventCapacity = 250_000
    nonisolated private static let recording = Atomic<Bool>(false)
    nonisolated private static let buffer = Mutex(Buffer())

    private static var startUptime: UInt64 = 0
    private static var startDate = Date()
    private static var startContext: [String: Any] = [:]
    private static var sampler: ProcessSampler?
    private static var hangObserver: CFRunLoopObserver?
    private static var sessionObserver: SessionObserver?
    private static var limitTask: Task<Void, Never>?

    nonisolated static var isRecording: Bool { recording.load(ordering: .relaxed) }

    static var startedAt: Date? { isRecording ? startDate : nil }

    nonisolated static func append(_ kind: Kind, _ category: StaticString, _ name: StaticString, _ id: UInt64, _ detail: String,
                                   at uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let event = Event(kind: kind, category: category, name: name, id: id, uptime: uptime, detail: detail, isMainThread: pthread_main_np() != 0)
        buffer.withLock {
            if $0.events.count < eventCapacity { $0.events.append(event) } else { $0.droppedEvents += 1 }
        }
    }

    /// `processes` is asked for the processes to follow every few seconds; `context` describes the
    /// session at its start. `onLimit` runs when the recording reaches `maxDuration`.
    static func start(processes: @escaping @MainActor () -> [Process], context: [String: Any], onLimit: @escaping @MainActor () -> Void) {
        guard !isRecording else { return }
        buffer.withLock { $0 = Buffer() }
        startUptime = DispatchTime.now().uptimeNanoseconds
        startDate = Date()
        startContext = context
        recording.store(true, ordering: .relaxed)

        sampler = ProcessSampler(processes: processes)
        installHangObserver()
        sessionObserver = SessionObserver()
        limitTask = Task {
            try? await Task.sleep(for: maxDuration)
            if !Task.isCancelled { onLimit() }
        }
    }

    /// Stops the recording and writes the trace into `directory`. Returns the file, or nil when
    /// nothing was recording or the write failed.
    static func stop(writingTo directory: URL) async -> URL? {
        guard isRecording else { return nil }
        recording.store(false, ordering: .relaxed)
        limitTask?.cancel()
        limitTask = nil
        sampler?.cancel()
        sampler = nil
        if let hangObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), hangObserver, .commonModes) }
        hangObserver = nil
        sessionObserver?.invalidate()
        sessionObserver = nil

        let stopUptime = DispatchTime.now().uptimeNanoseconds
        let recorded = buffer.withLock { buffer in
            defer { buffer = Buffer() }
            return buffer
        }
        var metadata = startContext
        metadata["startedAt"] = ISO8601DateFormatter().string(from: startDate)
        metadata["durationSeconds"] = Double(stopUptime - startUptime) / 1_000_000_000
        metadata["droppedEvents"] = recorded.droppedEvents
        metadata["thermalStateAtStop"] = ProcessInfo.processInfo.thermalState.rawValue
        metadata["runtimePercentiles"] = StartupMetrics.runtimePercentiles().map {
            ["name": $0.name, "count": $0.count, "p50Milliseconds": $0.p50, "p95Milliseconds": $0.p95, "maxMilliseconds": $0.max]
        }
        let marks = StartupMetrics.marks(since: startUptime)
        let start = startUptime
        let fileName = "Lilo-perf-\(Self.fileDateFormatter.string(from: startDate)).json"
        let metadataData = (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data("{}".utf8)

        return await Task.detached(priority: .utility) {
            var metadataObject = metadataData
            if let metricKit = MetricKitArchive.storedPayloadsJSON() {
                // Splices the archived payloads in as `metricKit` without re-parsing them.
                metadataObject.removeLast()
                metadataObject.append(contentsOf: Data((metadataObject.count > 1 ? ",\"metricKit\":" : "\"metricKit\":").utf8))
                metadataObject.append(metricKit)
                metadataObject.append(UInt8(ascii: "}"))
            }
            let data = traceJSON(events: recorded.events, samples: recorded.samples, marks: marks, startUptime: start, metadata: metadataObject)
            let url = directory.appendingPathComponent(fileName)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    // MARK: - Main-thread hangs

    private static var lastWake: UInt64 = 0
    private static var hangCount: UInt64 = 0

    /// Times each main run loop pass, from waking to going back to sleep; a long pass is a hang.
    private static func installHangObserver() {
        lastWake = DispatchTime.now().uptimeNanoseconds
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated {
                let now = DispatchTime.now().uptimeNanoseconds
                if activity == .afterWaiting {
                    lastWake = now
                } else if now - lastWake > hangThreshold {
                    hangCount += 1
                    append(.begin, "main", "hang", hangCount, "", at: lastWake)
                    append(.end, "main", "hang", hangCount, "", at: now)
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        hangObserver = observer
    }

    // MARK: - Trace file

    /// Chrome Trace Event JSON, written in one pass. Pids are local numbers (Lilo is 1): the
    /// real ones mean nothing outside the recorded Mac.
    nonisolated static func traceJSON(events: [Event], samples: [Sample], marks: [(uptime: UInt64, event: String)],
                                      startUptime: UInt64, metadata: Data) -> Data {
        var out = Data()
        out.reserveCapacity(events.count * 120 + samples.count * 600 + metadata.count + 1024)
        func write(_ string: String) { out.append(contentsOf: string.utf8) }
        func writeString(_ string: String) {
            out.append(UInt8(ascii: "\""))
            for byte in string.utf8 {
                switch byte {
                case UInt8(ascii: "\""): write("\\\"")
                case UInt8(ascii: "\\"): write("\\\\")
                case 0..<0x20: write(String(format: "\\u%04x", byte))
                default: out.append(byte)
                }
            }
            out.append(UInt8(ascii: "\""))
        }
        func micros(_ uptime: UInt64) -> String {
            String(Double(uptime &- startUptime) / 1000)
        }
        var first = true
        func writeHead(_ phase: String, _ category: String, _ name: String, pid: Int, tid: Int, ts: String) {
            write(first ? "\n" : ",\n")
            first = false
            write("{\"ph\":\"\(phase)\",\"cat\":")
            writeString(category)
            write(",\"name\":")
            writeString(name)
            write(",\"pid\":\(pid),\"tid\":\(tid),\"ts\":\(ts)")
        }

        write("{\"displayTimeUnit\":\"ms\",\"metadata\":")
        out.append(metadata)
        write(",\"traceEvents\":[")

        var localPids: [Int32: Int] = [getpid(): 1]
        var processNames = [(1, "Lilo")]
        var roleCounts: [String: Int] = [:]
        for sample in samples where localPids[sample.process.pid] == nil {
            let local = localPids.count + 1
            localPids[sample.process.pid] = local
            roleCounts[sample.process.role, default: 0] += 1
            processNames.append((local, "\(sample.process.role) \(roleCounts[sample.process.role]!)"))
        }
        for (pid, name) in processNames {
            writeHead("M", "__metadata", "process_name", pid: pid, tid: 0, ts: "0")
            write(",\"args\":{\"name\":")
            writeString(name)
            write("}}")
        }
        for (tid, name) in [(1, "main"), (2, "background")] {
            writeHead("M", "__metadata", "thread_name", pid: 1, tid: tid, ts: "0")
            write(",\"args\":{\"name\":\"\(name)\"}}")
        }

        // Ends pair with the latest open begin of the same category, name and id, so nested
        // exclusive intervals close inside out.
        var openBegins: [String: [Int]] = [:]
        var endOf: [Int: Int] = [:]
        var unmatchedEnds: Set<Int> = []
        for (index, event) in events.enumerated() where event.kind != .event {
            let key = "\(event.category)|\(event.name)|\(event.id)"
            if event.kind == .begin {
                openBegins[key, default: []].append(index)
            } else if let begin = openBegins[key]?.popLast() {
                endOf[begin] = index
            } else {
                unmatchedEnds.insert(index)
            }
        }
        var tabNumbers: [UInt64: Int] = [:]
        for (index, event) in events.enumerated() {
            let category = "\(event.category)", name = "\(event.name)"
            let tid = event.isMainThread ? 1 : 2
            switch event.kind {
            case .begin:
                let end = endOf[index].map { events[$0] }
                writeHead(end == nil ? "B" : "X", category, name, pid: 1, tid: tid, ts: micros(event.uptime))
                if let end { write(",\"dur\":\(Double(end.uptime &- event.uptime) / 1000)") }
                write(",\"args\":{")
                var separator = ""
                if !event.detail.isEmpty { write("\"detail\":"); writeString(event.detail); separator = "," }
                if let end, !end.detail.isEmpty { write("\(separator)\"result\":"); writeString(end.detail); separator = "," }
                if category == "navigation" {
                    let tab = tabNumbers[event.id] ?? (tabNumbers.count + 1)
                    tabNumbers[event.id] = tab
                    write("\(separator)\"tab\":\(tab)")
                }
                write("}}")
            case .end:
                guard unmatchedEnds.contains(index) else { continue }
                writeHead("i", category, name, pid: 1, tid: tid, ts: micros(event.uptime))
                write(",\"s\":\"t\",\"args\":{\"end\":true")
                if !event.detail.isEmpty { write(",\"result\":"); writeString(event.detail) }
                write("}}")
            case .event:
                writeHead("i", category, name, pid: 1, tid: tid, ts: micros(event.uptime))
                write(",\"s\":\"t\"")
                if !event.detail.isEmpty { write(",\"args\":{\"detail\":"); writeString(event.detail); write("}") }
                write("}")
            }
        }
        for mark in marks {
            writeHead("i", "startup", mark.event, pid: 1, tid: 1, ts: micros(mark.uptime))
            write(",\"s\":\"p\"}")
        }
        for sample in samples {
            let pid = localPids[sample.process.pid] ?? 0
            let ts = micros(sample.uptime)
            let counters: [(String, Double)] = [
                ("cpu %", sample.cpuPercent),
                ("footprint MB", Double(sample.footprintBytes) / 1_048_576),
                ("wakeups/s", sample.wakeupsPerSecond),
                ("disk read KB/s", sample.diskReadBytesPerSecond / 1024),
                ("disk write KB/s", sample.diskWriteBytesPerSecond / 1024),
                ("power mW", sample.milliwatts)
            ]
            for (name, value) in counters {
                writeHead("C", "process", name, pid: pid, tid: 0, ts: ts)
                write(",\"args\":{\"value\":\((value * 10).rounded() / 10)}}")
            }
        }
        write("\n]}\n")
        return out
    }
}

/// Reads every followed process twice a second on its own queue. The list of processes comes from
/// the main actor every 5 seconds: tabs open, close and change process meanwhile.
private final class ProcessSampler: @unchecked Sendable {
    private struct Reading {
        let uptime: UInt64
        let cpu: UInt64
        let wakeups: UInt64
        let diskRead: UInt64
        let diskWrite: UInt64
        let energy: UInt64
    }

    private let queue = DispatchQueue(label: "fr.arouillard.lilo.perf-sampler", qos: .utility)
    private let timer: DispatchSourceTimer
    private let ownProcess = PerfRecorder.Process(pid: getpid(), role: "lilo")
    private var processes: [PerfRecorder.Process] = []
    private var previous: [Int32: Reading] = [:]
    private var ticks = 0

    init(processes provider: @escaping @MainActor () -> [PerfRecorder.Process]) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if ticks % 10 == 0 {
                DispatchQueue.main.async { [weak self] in
                    let list = MainActor.assumeIsolated { provider() }
                    guard let self else { return }
                    queue.async { self.processes = list }
                }
            }
            ticks += 1
            sample()
        }
        timer.resume()
    }

    func cancel() { timer.cancel() }

    private func sample() {
        var samples: [PerfRecorder.Sample] = []
        var seen: Set<Int32> = []
        for process in [ownProcess] + processes where seen.insert(process.pid).inserted {
            guard let usage = ProcessTaskInfoSampler.usage(pid: process.pid) else { continue }
            let reading = Reading(
                uptime: DispatchTime.now().uptimeNanoseconds,
                cpu: ProcessTaskInfoSampler.cpuNanoseconds(usage),
                wakeups: usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups,
                diskRead: usage.ri_diskio_bytesread,
                diskWrite: usage.ri_diskio_byteswritten,
                energy: usage.ri_energy_nj
            )
            defer { previous[process.pid] = reading }
            guard let last = previous[process.pid], reading.uptime > last.uptime else { continue }
            let seconds = Double(reading.uptime - last.uptime) / 1_000_000_000
            let rate = { (now: UInt64, before: UInt64) in Double(now &- before) / seconds }
            samples.append(PerfRecorder.Sample(
                process: process,
                uptime: reading.uptime,
                cpuPercent: rate(reading.cpu, last.cpu) / 10_000_000,
                footprintBytes: usage.ri_phys_footprint,
                wakeupsPerSecond: rate(reading.wakeups, last.wakeups),
                diskReadBytesPerSecond: rate(reading.diskRead, last.diskRead),
                diskWriteBytesPerSecond: rate(reading.diskWrite, last.diskWrite),
                milliwatts: rate(reading.energy, last.energy) / 1_000_000
            ))
        }
        previous = previous.filter { seen.contains($0.key) }
        PerfRecorder.appendSamples(samples)
    }
}

extension PerfRecorder {
    nonisolated fileprivate static func appendSamples(_ samples: [Sample]) {
        buffer.withLock { $0.samples.append(contentsOf: samples) }
    }
}

/// Menu actions, app activation and dropped frames during a recording. Frames are frames the window
/// server expected but the main thread did not deliver; the display link wakes the main thread every
/// frame, so it runs only while recording, and only while Lilo is frontmost.
@MainActor
private final class SessionObserver: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    override init() {
        super.init()
        link = (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        link?.isPaused = !NSApp.isActive
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuAction(_:)), name: NSMenu.didSendActionNotification, object: nil)
        center.addObserver(self, selector: #selector(activeChanged(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(activeChanged(_:)), name: NSApplication.didResignActiveNotification, object: nil)
    }

    /// The display link retains its target: invalidating it frees the observer, and its notifications with it.
    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func menuAction(_ note: Notification) {
        let action = (note.userInfo?["MenuItem"] as? NSMenuItem)?.action.map(NSStringFromSelector)
        PerfSignposts.input.emitEvent("menu", action ?? "unknown")
    }

    @objc private func activeChanged(_ note: Notification) {
        let active = note.name == NSApplication.didBecomeActiveNotification
        link?.isPaused = !active
        lastTimestamp = 0
        PerfSignposts.input.emitEvent(active ? "appActive" : "appInactive")
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        let frame = link.targetTimestamp - link.timestamp
        guard lastTimestamp > 0, frame > 0 else { return }
        let gap = link.timestamp - lastTimestamp
        if gap > frame * 1.5 {
            PerfRecorder.append(.event, "frames", "drop", 0, String(Int((gap / frame).rounded()) - 1))
        }
    }
}
