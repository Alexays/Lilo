import Foundation
import OSLog

@MainActor
enum StartupMetrics {
    private struct Mark {
        let id = UUID()
        let timestamp: Date
        let event: String
        let uptime: UInt64
        let totalMilliseconds: Double
        var deltaMilliseconds: Double
    }

    private struct Trace {
        let id = UUID()
        let timestamp = Date()
        let category: String
        let message: String
        let totalMilliseconds: Double
    }

    private static let logger = Logger(liloCategory: "startup")
    private static let traceLogger = Logger(liloCategory: "trace")
    /// Process launch on the uptime clock, from the kernel's start time: dyld and pre-main work count.
    private static let startTime: UInt64 = {
        let now = DispatchTime.now().uptimeNanoseconds
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return now }
        let launch = info.kp_proc.p_un.__p_starttime
        let elapsed = Date().timeIntervalSince1970 - (Double(launch.tv_sec) + Double(launch.tv_usec) / 1_000_000)
        return now - min(now, UInt64(max(0, elapsed) * 1_000_000_000))
    }()
    private static let markCapacity = 256
    private static let traceCapacity = 512
    private static let sampleCapacity = 512
    /// Marks/traces included in a bridge snapshot or text export; older entries are dropped.
    private static let exportEntryLimit = 200
    private static var marks: [Mark] = []
    private static var traces: [Trace] = []
    private static var runtimeSamples: [String: [Double]] = [:]
    private static var lastProgressUpdateTime: UInt64?
    private static var onceEvents: Set<String> = []
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func markOnce(_ event: String, occurredAt epochMilliseconds: Double? = nil) {
        guard onceEvents.insert(event).inserted else { return }
        mark(event, occurredAt: epochMilliseconds)
    }

    /// `occurredAt` (Unix epoch milliseconds) dates a mark taken in another process: the chrome's marks
    /// land when they happened, not when the main thread got around to the message.
    static func mark(_ event: String, occurredAt epochMilliseconds: Double? = nil) {
        let now = DispatchTime.now().uptimeNanoseconds
        let lag = epochMilliseconds.map { UInt64(max(0, Date().timeIntervalSince1970 * 1000 - $0) * 1_000_000) } ?? 0
        let time = now - min(lag, now - startTime)

        // A late-delivered mark slots in among the ones recorded meanwhile, and its successor's delta follows.
        var index = marks.endIndex
        while index > marks.startIndex, marks[index - 1].uptime > time { index -= 1 }
        let previous = index > marks.startIndex ? marks[index - 1].uptime : startTime
        let totalMilliseconds = milliseconds(from: startTime, to: time)
        let deltaMilliseconds = milliseconds(from: previous, to: time)
        marks.insert(Mark(timestamp: Date(timeIntervalSinceNow: -Double(now - time) / 1_000_000_000), event: event,
                          uptime: time, totalMilliseconds: totalMilliseconds, deltaMilliseconds: deltaMilliseconds), at: index)
        if index + 1 < marks.endIndex {
            marks[index + 1].deltaMilliseconds = milliseconds(from: time, to: marks[index + 1].uptime)
        }
        trim(&marks, capacity: markCapacity)
        logger.notice("startup event=\(event, privacy: .public) total_ms=\(format(totalMilliseconds), privacy: .public) delta_ms=\(format(deltaMilliseconds), privacy: .public)")
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000_000 : 0
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    /// Traces are diagnostics-only; marks stay ungated because the Diagnostics panel needs them.
    #if DEBUG
    static let tracingEnabled = true
    #else
    static let tracingEnabled = UserDefaults.lilo.bool(forKey: "LiloTracingEnabled")
    #endif

    static func trace(_ category: String, _ message: @autoclosure () -> String) {
        guard tracingEnabled else { return }
        let totalMilliseconds = milliseconds(from: startTime, to: DispatchTime.now().uptimeNanoseconds)
        let message = message()
        traces.append(Trace(category: category, message: message, totalMilliseconds: totalMilliseconds))
        trim(&traces, capacity: traceCapacity)
        traceLogger.notice("trace total_ms=\(format(totalMilliseconds), privacy: .public) category=\(category, privacy: .public) \(message, privacy: .public)")
    }

    /// High-water trim: `removeFirst` is O(n), so the buffer grows to `capacity * 2` and trims back
    /// to `capacity` in one bulk shift, amortizing the cost to O(1) per append.
    private static func trim<T>(_ entries: inout [T], capacity: Int) {
        if entries.count >= capacity * 2 { entries.removeFirst(entries.count - capacity) }
    }

    static func spaceOrderDescription(_ spaces: [Space]) -> String {
        spaces.enumerated()
            .map { index, space in "\(index):\(space.id.uuidString.prefix(8)):\(space.sortOrder)\(space.isPrivate ? ":private" : "")" }
            .joined(separator: ",")
    }

    private static func lastTotal(of event: String) -> Double? {
        marks.last(where: { $0.event == event })?.totalMilliseconds
    }

    /// Name, count, p50, p95 and max of each runtime sample series, by name.
    private static func runtimePercentiles() -> [(name: String, count: Int, p50: Double, p95: Double, max: Double)] {
        runtimeSamples.keys.sorted().compactMap { name in
            guard let values = runtimeSamples[name]?.sorted(), let max = values.last else { return nil }
            let percentile = { (p: Double) in values[Int((Double(values.count - 1) * p).rounded(.toNearestOrAwayFromZero))] }
            return (name, values.count, percentile(0.5), percentile(0.95), max)
        }
    }

    static func bridgeSnapshot() -> [String: Any] {
        let visibleMarks = marks.suffix(exportEntryLimit)
        var summary: [String: Any] = [:]
        summary["chromeVisualReadyMilliseconds"] = lastTotal(of: "chromeVisualReady")
        // Boot falls back to the latest visible mark until chromeVisualReady has fired.
        summary["bootDurationMilliseconds"] = lastTotal(of: "chromeVisualReady") ?? visibleMarks.last?.totalMilliseconds
        return [
            "summary": summary,
            "marks": visibleMarks.map {
                ["id": $0.id.uuidString, "timestamp": $0.timestamp.timeIntervalSince1970, "event": $0.event,
                 "totalMilliseconds": $0.totalMilliseconds, "deltaMilliseconds": $0.deltaMilliseconds] as [String: Any]
            },
            "traces": traces.suffix(exportEntryLimit).map {
                ["id": $0.id.uuidString, "timestamp": $0.timestamp.timeIntervalSince1970, "category": $0.category,
                 "message": $0.message, "totalMilliseconds": $0.totalMilliseconds] as [String: Any]
            }
        ]
    }

    static func exportText() -> String {
        let visibleMarks = marks.suffix(exportEntryLimit)
        let visibleTraces = traces.suffix(exportEntryLimit)
        let percentiles = runtimePercentiles()
        let summary = { (milliseconds: Double?) in milliseconds.map { "\(format($0)) ms" } ?? "--" }
        var lines = [
            "Lilo Startup Metrics",
            "Generated: \(timestampFormatter.string(from: Date()))",
            "Bundle ID: \(Bundle.main.bundleIdentifier ?? "")",
            "Bundle Path: \(Bundle.main.bundleURL.path)",
            "",
            "Summary",
            "- Boot (chrome visual ready): \(summary(lastTotal(of: "chromeVisualReady") ?? visibleMarks.last?.totalMilliseconds))",
            "- Chrome Ready: \(summary(lastTotal(of: "chromeReady")))",
            "- First Content Finished: \(summary(lastTotal(of: "firstContentFinished")))",
            "- Marks: \(marks.count)",
            "- Traces: \(traces.count)",
            // Most recent mark of the whole session (often a user nav long after boot), not a boot figure.
            "- Last session mark: \(visibleMarks.last?.event ?? "") @ \(summary(visibleMarks.last?.totalMilliseconds))"
        ]
        if !percentiles.isEmpty {
            lines += ["- Runtime Percentiles: \(percentiles.count)", "", "Runtime Percentiles",
                      "(intervals are wall-clock gaps between events across the whole session, not cold-start durations)"]
            lines += percentiles.map {
                "- \($0.name): count=\($0.count) p50=\(summary($0.p50)) p95=\(summary($0.p95)) max=\(summary($0.max))"
            }
        }
        lines += ["", "Marks"]
        lines += visibleMarks.isEmpty ? ["No startup marks recorded."] : visibleMarks.map {
            "- [\(timestampFormatter.string(from: $0.timestamp))] \($0.event) total_ms=\(format($0.totalMilliseconds)) delta_ms=\(format($0.deltaMilliseconds))"
        }
        lines += ["", "Traces"]
        lines += visibleTraces.isEmpty ? ["No runtime traces recorded."] : visibleTraces.map {
            "- [\(timestampFormatter.string(from: $0.timestamp))] \($0.category) total_ms=\(format($0.totalMilliseconds)) \($0.message)"
        }
        return lines.joined(separator: "\n")
    }

    static func recordDurationSample(_ name: String, startUptime: UInt64) {
        recordSample(name, milliseconds: milliseconds(from: startUptime, to: DispatchTime.now().uptimeNanoseconds))
    }

    static func recordProgressUpdateSample() {
        let now = DispatchTime.now().uptimeNanoseconds
        lastProgressUpdateTime.map { recordSample("progressUpdateInterval", milliseconds: milliseconds(from: $0, to: now)) }
        lastProgressUpdateTime = now
    }

    private static func recordSample(_ name: String, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        // Mutated through the subscript so the buffer stays uniquely referenced: pulling the array
        // into a local would CoW-copy it on every sample.
        runtimeSamples[name, default: []].append(milliseconds)
        if let count = runtimeSamples[name]?.count, count >= sampleCapacity * 2 {
            runtimeSamples[name]?.removeFirst(count - sampleCapacity)
        }
    }
}
