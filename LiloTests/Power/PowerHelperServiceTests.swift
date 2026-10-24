import XCTest
@testable import Lilo

final class PowerHelperServiceTests: XCTestCase {
    private final class FakeBackend: PowerBackend {
        var sleepDisabled = false
        var lowPower = false
        var processes: [pid_t: (start: UInt64, uid: uid_t)] = [:]
        var signals: [(signal: Int32, pid: pid_t)] = []
        func setSleepDisabled(_ disabled: Bool) -> Bool { sleepDisabled = disabled; return true }
        func lowPowerMode() -> Bool? { lowPower }
        var lowPowerFails = false
        func setLowPowerMode(_ on: Bool) -> Bool {
            guard !lowPowerFails else { return false }
            lowPower = on
            return true
        }
        var stopped = Set<pid_t>()
        var sleepRequests = 0
        func process(_ pid: pid_t) -> (start: UInt64, uid: uid_t, stopped: Bool)? {
            processes[pid].map { ($0.start, $0.uid, stopped.contains(pid)) }
        }
        func send(_ signal: Int32, to pid: pid_t) { signals.append((signal, pid)) }
        func sleepIfLidClosed() { sleepRequests += 1 }
    }

    private var stateURL: URL!

    override func setUp() {
        stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("power-\(UUID().uuidString)/state.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
    }

    private func call(_ body: (@escaping () -> Void) -> Void) {
        let done = expectation(description: "reply")
        body { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testSleepStaysOffWhileAnySessionHoldsIt() {
        let backend = FakeBackend()
        let service = PowerHelperService(backend: backend, stateURL: stateURL)
        let installed = service.makeSession(uid: 501, pid: 901), debug = service.makeSession(uid: 501, pid: 902)
        call { done in installed.holdAwake { _ in done() } }
        call { done in debug.holdAwake { _ in done() } }

        installed.end()
        XCTAssertTrue(backend.sleepDisabled, "the other app still works")
        debug.end()
        XCTAssertFalse(backend.sleepDisabled)
    }

    func testEndingASessionUndoesEverythingItAskedFor() {
        let backend = FakeBackend()
        backend.processes = [42: (start: 7, uid: 501)]
        let service = PowerHelperService(backend: backend, stateURL: stateURL)
        let session = service.makeSession(uid: 501, pid: 903)
        call { done in session.holdAwake { _ in done() } }
        call { done in session.setLowPowerMode(true) { _ in done() } }
        call { done in session.freeze(pids: [42], starts: [7]) { _ in done() } }

        // The connection dropped: no release, no thaw, Lilo is gone.
        session.end()

        XCTAssertFalse(backend.sleepDisabled)
        XCTAssertFalse(backend.lowPower)
        XCTAssertEqual(backend.signals.map(\.signal), [SIGSTOP, SIGCONT])
    }

    func testNothingChangesThatTheStateFileCannotRecord() throws {
        // A file where the state's folder should be: no state can be written.
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent().deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: stateURL.deletingLastPathComponent())
        let backend = FakeBackend()
        backend.processes = [42: (start: 7, uid: 501)]
        let session = PowerHelperService(backend: backend, stateURL: stateURL).makeSession(uid: 501, pid: 905)
        var held = true, frozen: [NSNumber] = [1]
        call { done in session.holdAwake { held = $0; done() } }
        call { done in session.freeze(pids: [42], starts: [7]) { frozen = $0; done() } }

        XCTAssertFalse(held)
        XCTAssertFalse(backend.sleepDisabled)
        XCTAssertEqual(frozen, [])
        XCTAssertTrue(backend.signals.isEmpty)
    }

    func testAFailedLowPowerSwitchIsTriedAgain() {
        let backend = FakeBackend()
        backend.lowPowerFails = true
        let session = PowerHelperService(backend: backend, stateURL: stateURL).makeSession(uid: 501, pid: 906)
        var switched = true
        call { done in session.setLowPowerMode(true) { switched = $0; done() } }
        XCTAssertFalse(switched)

        backend.lowPowerFails = false
        call { done in session.setLowPowerMode(true) { switched = $0; done() } }

        XCTAssertTrue(switched)
        XCTAssertTrue(backend.lowPower)
    }

    func testLowPowerModeTheUserHadOnStaysOn() {
        let backend = FakeBackend()
        backend.lowPower = true
        let session = PowerHelperService(backend: backend, stateURL: stateURL).makeSession(uid: 501, pid: 904)
        call { done in session.setLowPowerMode(true) { _ in done() } }
        session.end()
        XCTAssertTrue(backend.lowPower)
    }

    func testFreezeRefusesAnotherUserRootAndAStaleIdentity() {
        let backend = FakeBackend()
        backend.processes = [10: (start: 1, uid: 501), 11: (start: 1, uid: 502), 12: (start: 1, uid: 0), 13: (start: 2, uid: 501)]
        let session = PowerHelperService(backend: backend, stateURL: stateURL).makeSession(uid: 501, pid: 905)
        var stopped: [NSNumber] = []
        call { done in session.freeze(pids: [10, 11, 12, 13], starts: [1, 1, 1, 1]) { stopped = $0; done() } }
        XCTAssertEqual(stopped, [10])
    }

    func testThawSkipsAProcessWhosePidWasReused() {
        let backend = FakeBackend()
        backend.processes = [42: (start: 7, uid: 501)]
        let session = PowerHelperService(backend: backend, stateURL: stateURL).makeSession(uid: 501, pid: 906)
        call { done in session.freeze(pids: [42], starts: [7]) { _ in done() } }
        backend.processes[42] = (start: 9, uid: 501)
        call { done in session.thaw { done() } }
        XCTAssertEqual(backend.signals.map(\.signal), [SIGSTOP])
    }

    func testFreezeRefusesAConnectedClient() {
        let backend = FakeBackend()
        backend.processes = [700: (start: 1, uid: 501)]
        let service = PowerHelperService(backend: backend, stateURL: stateURL)
        // Kept alive like the XPC connection keeps its session: claims are keyed by identity.
        let client = service.makeSession(uid: 501, pid: 700)
        let other = service.makeSession(uid: 501, pid: 701)
        var stopped: [NSNumber] = []
        call { done in other.freeze(pids: [700], starts: [1]) { stopped = $0; done() } }
        XCTAssertEqual(stopped, [], "another Lilo stopped could never give back what it holds")
        withExtendedLifetime(client) {}
    }

    func testReleaseAllGivesEverythingBackAndCountsTheOtherClients() {
        let backend = FakeBackend()
        backend.processes = [42: (start: 7, uid: 501)]
        let service = PowerHelperService(backend: backend, stateURL: stateURL)
        let installed = service.makeSession(uid: 501, pid: 800)
        let debug = service.makeSession(uid: 501, pid: 801)
        defer { withExtendedLifetime(debug) {} }
        call { done in installed.holdAwake { _ in done() } }
        call { done in installed.freeze(pids: [42], starts: [7]) { _ in done() } }
        var others = -1
        call { done in installed.releaseAll { others = $0; done() } }
        XCTAssertEqual(backend.sleepRequests, 1, "a released closed Mac sleeps now, not at the next idle timeout")
        XCTAssertEqual(others, 1)
        XCTAssertFalse(backend.sleepDisabled)
        XCTAssertEqual(backend.signals.map(\.signal), [SIGSTOP, SIGCONT])
    }

    func testEndAllUndoesEverySessionWhenTheHelperIsStopped() {
        let backend = FakeBackend()
        let service = PowerHelperService(backend: backend, stateURL: stateURL)
        let first = service.makeSession(uid: 501, pid: 810), second = service.makeSession(uid: 501, pid: 811)
        call { done in first.holdAwake { _ in done() } }
        call { done in second.setLowPowerMode(true) { _ in done() } }

        service.endAll()

        XCTAssertFalse(backend.sleepDisabled)
        XCTAssertFalse(backend.lowPower)
    }

    func testFreezeLeavesAJobTheUserStoppedAlone() {
        let backend = FakeBackend()
        backend.processes = [42: (start: 7, uid: 501)]
        backend.stopped = [42]
        let session = PowerHelperService(backend: backend, stateURL: stateURL).makeSession(uid: 501, pid: 908)
        var stopped: [NSNumber] = []
        call { done in session.freeze(pids: [42], starts: [7]) { stopped = $0; done() } }
        session.end()
        XCTAssertEqual(stopped, [])
        XCTAssertTrue(backend.signals.isEmpty, "never resumed behind the user's back")
    }

    func testEndAllNeverSleepsTheMacWhileTheHelperStops() {
        let backend = FakeBackend()
        let service = PowerHelperService(backend: backend, stateURL: stateURL)
        let session = service.makeSession(uid: 501, pid: 909)
        call { done in session.holdAwake { _ in done() } }
        service.endAll()
        XCTAssertEqual(backend.sleepRequests, 0, "a shutdown is under way")
    }

    func testDroppingARealConnectionGivesEverythingBack() {
        let backend = FakeBackend()
        let delegate = PowerHelperListener(service: PowerHelperService(backend: backend, stateURL: stateURL), onIdle: {})
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.resume()
        let held = expectation(description: "held")
        (connection.remoteObjectProxy as? PowerHelperProtocol)?.holdAwake { _ in held.fulfill() }
        wait(for: [held], timeout: 2)
        XCTAssertTrue(backend.sleepDisabled)

        connection.invalidate()

        let deadline = Date().addingTimeInterval(2)
        while backend.sleepDisabled, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(backend.sleepDisabled)
    }

    func testRelaunchUndoesWhatACrashedRunLeft() {
        let backend = FakeBackend()
        backend.processes = [42: (start: 7, uid: 501)]
        let session = PowerHelperService(backend: backend, stateURL: stateURL).makeSession(uid: 501, pid: 907)
        call { done in session.holdAwake { _ in done() } }
        call { done in session.freeze(pids: [42], starts: [7]) { _ in done() } }

        // The helper itself died: a new one starts from the state file.
        _ = PowerHelperService(backend: backend, stateURL: stateURL)

        XCTAssertFalse(backend.sleepDisabled)
        XCTAssertEqual(backend.signals.last?.signal, SIGCONT)
    }
}

@MainActor
final class PowerHelperLinkTests: XCTestCase {
    func testAdHocBuildCannotReachTheHelper() throws {
        // Test builds are signed ad hoc (CODE_SIGN_IDENTITY = -): no team, no requirement to check.
        try XCTSkipIf(PowerHelperIdentity.requirement(forIdentifier: PowerHelperIdentity.helperIdentifier) != nil, "signed build")
        XCTAssertNil(XPCPowerHelperLink())
        XCTAssertEqual(SMAppServiceInstaller().status, "unsigned")
    }
}
