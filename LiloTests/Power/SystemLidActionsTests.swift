import AppKit
import XCTest
@testable import Lilo

@MainActor
final class SystemLidActionsTests: XCTestCase {
    func testDescendantsCoverAProcessTree() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep 30 & wait"]
        try shell.run()
        // The sleep too: ending the shell alone leaves it running for 30 s.
        defer { AppFreezer.descendants(of: shell.processIdentifier).reversed().forEach { kill($0, SIGTERM) } }
        await pollUntil(timeout: 5) { AppFreezer.descendants(of: shell.processIdentifier).count == 2 }

        let tree = AppFreezer.descendants(of: shell.processIdentifier)

        XCTAssertEqual(tree.first, shell.processIdentifier)
        XCTAssertEqual(tree.count, 2, "the shell and its sleep")
    }

    func testDescendantsSkipThePrunedSubtree() {
        // Lilo launched from another terminal app sits in that app's tree.
        let tree = AppFreezer.descendants(of: getppid()) { $0 == getpid() }
        XCTAssertFalse(tree.contains(getpid()))
    }

    /// A Lilo another app runs, from its terminal say, keeps running with everything it started.
    func testAnotherLiloInATargetsTreeIsSparedWithItsChildren() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lilo = directory.appendingPathComponent("Lilo")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: lilo.path)
        // A copied system binary no longer matches its signature and is killed at launch.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", lilo.path]
        try sign.run()
        sign.waitUntilExit()
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "'\(lilo.path)' 30 & /bin/sleep 30 & wait"]
        try shell.run()
        defer { AppFreezer.descendants(of: shell.processIdentifier).reversed().forEach { kill($0, SIGTERM) } }
        // The forked shell only becomes the Lilo once its exec, slow for a fresh signature, returns.
        await pollUntil(timeout: 5) {
            let tree = AppFreezer.descendants(of: shell.processIdentifier)
            return tree.count == 3 && tree.contains(where: AppFreezer.isLilo)
        }
        let everything = AppFreezer.descendants(of: shell.processIdentifier)
        XCTAssertEqual(everything.count, 3, "the shell, the Lilo and the sleep")

        let tree = AppFreezer.descendants(of: shell.processIdentifier, pruning: AppFreezer.isLilo)

        XCTAssertEqual(tree.count, 2, "the shell and its sleep")
        XCTAssertFalse(tree.contains(where: AppFreezer.isLilo))
        XCTAssertTrue(AppFreezer.isLilo(getpid()), "the test host is a Lilo too")
    }

    func testTargetsNeverIncludeLiloItsAncestorsOrAnotherLilo() {
        let pids = Set(AppFreezer.targets(keeping: []).map(\.pid))
        let ancestors = sequence(first: getppid()) { pid in
            SystemPowerBackend.info(pid).map { pid_t($0.pbi_ppid) }.flatMap { $0 > 1 && $0 != pid ? $0 : nil }
        }
        for pid in ancestors { XCTAssertFalse(pids.contains(pid), "ancestor \(pid)") }
        // An installed Lilo or another checkout's test host is another build. The list keeps the entries of
        // test hosts that already quit, whose pid another process may run now: only a live Lilo counts.
        for app in NSWorkspace.shared.runningApplications where AppFreezer.isLilo(app.processIdentifier) {
            XCTAssertFalse(pids.contains(app.processIdentifier), app.bundleIdentifier ?? "")
        }
    }

    func testTargetsSpareTheAppsAConnectedAgentRunsIn() throws {
        let targets = AppFreezer.targets(keeping: [])
        guard let app = NSWorkspace.shared.runningApplications.first(where: { app in targets.contains { $0.pid == app.processIdentifier } }) else {
            throw XCTSkip("no third-party app is running to freeze")
        }
        // A live app's newest child can exit before the targets read its ancestry: only one that outlives the read counts.
        var spared = false
        for _ in 0..<20 {
            let agent = AppFreezer.descendants(of: app.processIdentifier).last ?? app.processIdentifier
            spared = !AppFreezer.targets(keeping: [], sparing: [agent]).contains { $0.pid == app.processIdentifier }
            if spared || kill(agent, 0) == 0 { break }
        }

        XCTAssertTrue(spared, app.bundleIdentifier ?? "")
    }

    func testTargetsLeaveLiloAppleAppsAndKeptAppsAlone() {
        let running = NSWorkspace.shared.runningApplications
        let kept = Set(running.compactMap(\.bundleIdentifier).filter { !$0.hasPrefix("com.apple.") }.prefix(1))

        let pids = Set(AppFreezer.targets(keeping: kept).map(\.pid))

        XCTAssertFalse(pids.contains(getpid()))
        for app in running where app.bundleIdentifier?.hasPrefix("com.apple.") == true || kept.contains(app.bundleIdentifier ?? "") {
            XCTAssertFalse(pids.contains(app.processIdentifier), "\(app.bundleIdentifier ?? "") pid=\(app.processIdentifier) me=\(getpid()) lilo=\(AppFreezer.isLilo(app.processIdentifier)) path=\(app.executableURL?.path ?? "")")
        }
    }
}
