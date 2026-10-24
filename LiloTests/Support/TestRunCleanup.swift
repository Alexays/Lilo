import Foundation
import WebKit
import XCTest
@testable import Lilo

/// Removes test profiles' WebKit stores when the last concurrent run ends: all under make's test host, else only new ones.
/// A run ending while another goes on removes nothing: the other's network process may still have them open.
@objc(LiloTestRunCleanup)
final class TestRunCleanup: NSObject, XCTestObservation {
    private let webKitRoot: URL
    /// One marker per live run, named by its pid, beside the baseline the first run recorded.
    private let runs: URL
    private var baseline: URL { runs.appendingPathComponent("baseline") }
    private let keepsExisting: Bool

    init(webKitRoot: URL, keepsExisting: Bool = true) {
        self.webKitRoot = webKitRoot
        self.keepsExisting = keepsExisting
        runs = webKitRoot.appendingPathComponent("LiloTestRuns", isDirectory: true)
        super.init()
    }

    override convenience init() {
        let host = Bundle.main.bundleIdentifier ?? "fr.arouillard.lilo"
        self.init(webKitRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/\(host)"),
                  keepsExisting: !host.hasSuffix(".tests"))
        XCTestObservationCenter.shared.addTestObserver(self)
        // Login shells in tests skip the user's zsh config: it can take seconds to start and drop typed input.
        let zdotdir = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-tests-zdotdir")
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        setenv("ZDOTDIR", zdotdir.path, 1)
        // A loaded system can miss an exiting host's WebKit processes, and RunningBoard keeps idle ones suspended, so they
        // never see the host go and live on for hours: end every process this host launched before it exits.
        atexit {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return }
            let responsible = unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
            var pids = [pid_t](repeating: 0, count: 8192)
            let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
            let host = getpid()
            for pid in pids.prefix(Int(max(count, 0))) where pid != host && responsible(pid) == host { kill(pid, SIGKILL) }
        }
        // Each test host's defaults domain (UserDefaults.lilo) and filter list cache (FilterListService's
        // LiloTests-pid folder, tens of MB) outlive it: those of hosts gone go now.
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        for file in Self.leftByEndedHosts(in: preferences, prefix: UserDefaults.testDomainPrefix, suffix: ".plist") {
            UserDefaults.lilo.removePersistentDomain(forName: String(file.dropLast(".plist".count)))
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(file))
        }
        let temporary = FileManager.default.temporaryDirectory
        for folder in Self.leftByEndedHosts(in: temporary, prefix: "LiloTests-") {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(folder))
        }
    }

    /// The names in `directory` made of `prefix`, the pid of a process that ended, and `suffix`.
    private static func leftByEndedHosts(in directory: URL, prefix: String, suffix: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { name in
            guard name.hasPrefix(prefix), name.hasSuffix(suffix), let pid = pid_t(name.dropFirst(prefix.count).dropLast(suffix.count)) else { return false }
            // EPERM: the process lives but belongs to another user.
            return kill(pid, 0) != 0 && errno != EPERM
        }
    }

    private func entries() -> Set<String> {
        Set(["WebsiteDataStore", "WebExtensions"].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: webKitRoot.appendingPathComponent(folder).path)) ?? []).map { "\(folder)/\($0)" }
        })
    }

    /// Runs `body` holding the lock every test run shares, telling it whether another run still goes.
    private func withRunLock(_ body: (_ othersLive: Bool) -> Void) {
        try? FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let lock = open(runs.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
        flock(lock, LOCK_EX)
        defer { close(lock) }
        var othersLive = false
        for name in (try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? [] {
            guard let pid = pid_t(name), pid != getpid() else { continue }
            // EPERM: the process lives but belongs to another user.
            if kill(pid, 0) == 0 || errno == EPERM {
                othersLive = true
            } else {
                try? FileManager.default.removeItem(at: runs.appendingPathComponent(name))
            }
        }
        body(othersLive)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        MainActor.assumeIsolated { TestProfileIds.recycle() }
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        var leftovers: Set<String> = []
        withRunLock { othersLive in
            // A test host of its own holds nothing but test stores: alone, whatever is there was left by
            // a run killed before it could clean, and recording it in the baseline would keep it for ever.
            if !othersLive, !keepsExisting {
                leftovers = entries()
            }
            if !othersLive || !FileManager.default.fileExists(atPath: baseline.path) {
                try? (keepsExisting ? entries().subtracting(leftovers) : []).sorted().joined(separator: "\n")
                    .write(to: baseline, atomically: true, encoding: .utf8)
            }
            FileManager.default.createFile(atPath: runs.appendingPathComponent("\(getpid())").path, contents: nil)
        }
        remove(leftovers)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        var created: Set<String> = []
        withRunLock { othersLive in
            try? FileManager.default.removeItem(at: runs.appendingPathComponent("\(getpid())"))
            guard !othersLive, let recorded = try? String(contentsOf: baseline, encoding: .utf8) else { return }
            created = entries().subtracting(recorded.split(separator: "\n").map(String.init))
            try? FileManager.default.removeItem(at: baseline)
        }
        remove(created)
    }

    private func remove(_ entries: Set<String>) {
        let dataStores = entries.compactMap { $0.hasPrefix("WebsiteDataStore/") ? UUID(uuidString: String($0.dropFirst(17))) : nil }
        // XCTest calls observers on the main thread.
        MainActor.assumeIsolated {
            var pending = dataStores.count
            for identifier in dataStores {
                // WebKit's own removal also ends the processes still holding the store.
                WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in pending -= 1 }
            }
            let deadline = Date().addingTimeInterval(20)
            while pending > 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        for entry in entries {
            try? FileManager.default.removeItem(at: webKitRoot.appendingPathComponent(entry))
        }
    }
}
