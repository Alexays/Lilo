import Foundation

/// Finds the `coordinate` binary without running it: the daemon-side scheduler is optional, and
/// probing by spawning it would cost a process per launch. A GUI app's `PATH` is minimal, so the
/// usual install directories are checked too.
public enum CoordinateLocator {
    public static func locate(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let known = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        let directories = (path ?? "").split(separator: ":").map(String.init) + known
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("coordinate")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// The durable `PluginScheduler`: each arm is a `coordinate enqueue --run-at` job whose command
/// drops a marker file in `spool/fired`, so a fire survives Lilo being quit — the next `resume`
/// delivers it. Nothing runs in Lilo while jobs wait: the daemon owns the clock.
///
/// A re-armed or cancelled id cancels its coordinate job through the id recorded in
/// `spool/armed`. Fires are delivered at least once; the plugin dedupes. When `enqueue` fails
/// (an older coordinate without `--run-at`, a broken install) the job runs on `fallback`
/// instead: not durable, but never silently dropped.
public final class CoordinatePluginScheduler: PluginScheduler, @unchecked Sendable {
    /// Runs `executable arguments` and returns trimmed stdout, or nil when it failed.
    public typealias Runner = @Sendable (URL, [String]) -> String?

    private let executable: URL
    private let fired: URL
    private let armed: URL
    private let run: Runner
    private let fallback: any PluginScheduler
    private let queue = DispatchQueue(label: "lilo.plugin.coordinate-scheduler")
    private var fire: (@Sendable (String) -> Void)?
    private var watcher: DispatchSourceFileSystemObject?

    public init(
        executable: URL, spool: URL, fallback: any PluginScheduler = ClockPluginScheduler(),
        run: @escaping Runner = CoordinatePluginScheduler.runProcess
    ) {
        self.fallback = fallback
        self.executable = executable
        fired = spool.appendingPathComponent("fired", isDirectory: true)
        armed = spool.appendingPathComponent("armed", isDirectory: true)
        self.run = run
    }

    deinit { watcher?.cancel() }

    public func schedule(_ jobID: String, after delay: TimeInterval, fire: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            self.fire = fire
            let name = Self.fileName(for: jobID)
            let fm = FileManager.default
            try? fm.createDirectory(at: armed, withIntermediateDirectories: true)
            try? fm.createDirectory(at: fired, withIntermediateDirectories: true)
            dropPending(name, jobID: jobID)
            let marker = ["sh", "-c", #"mkdir -p "$1" && : > "$1/$2""#, "sh", fired.path, name]
            let arguments = ["enqueue", "--run-at", "\(max(1, Int(delay.rounded(.up))))s", "--repo", "", "--"] + marker
            guard let id = run(executable, arguments), Int(id) != nil else {
                fallback.schedule(jobID, after: delay, fire: fire)
                return
            }
            try? id.write(to: armed.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    public func cancel(_ jobID: String) {
        queue.async { [self] in dropPending(Self.fileName(for: jobID), jobID: jobID) }
    }

    /// Delivers the fires that landed while nobody listened, then watches for new ones.
    public func resume(fire: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            self.fire = fire
            try? FileManager.default.createDirectory(at: fired, withIntermediateDirectories: true)
            deliverFired()
            guard watcher == nil else { return }
            let descriptor = open(fired.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: .write, queue: queue
            )
            source.setEventHandler { [weak self] in self?.deliverFired() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }
    }

    /// Stops watching; pending coordinate jobs stay queued.
    public func suspend() {
        queue.async { [self] in
            watcher?.cancel()
            watcher = nil
        }
    }

    /// Waits for queued work: tests use it instead of sleeping.
    func flush() { queue.sync {} }

    // MARK: - Spool

    private func deliverFired() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: fired.path)) ?? [] {
            guard let jobID = Self.jobID(forFileName: name) else { continue }
            fire?(jobID)
            try? fm.removeItem(at: fired.appendingPathComponent(name))
            try? fm.removeItem(at: armed.appendingPathComponent(name))
        }
    }

    private func dropPending(_ name: String, jobID: String) {
        fallback.cancel(jobID)
        let fm = FileManager.default
        let record = armed.appendingPathComponent(name)
        if let id = (try? String(contentsOf: record, encoding: .utf8)).flatMap({ Int($0) }) {
            _ = run(executable, ["cancel", String(id)])
        }
        try? fm.removeItem(at: record)
        try? fm.removeItem(at: fired.appendingPathComponent(name))
    }

    private static let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    private static func fileName(for jobID: String) -> String {
        jobID.addingPercentEncoding(withAllowedCharacters: safe) ?? jobID
    }

    private static func jobID(forFileName name: String) -> String? {
        name.removingPercentEncoding
    }

    public static func runProcess(_ executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
