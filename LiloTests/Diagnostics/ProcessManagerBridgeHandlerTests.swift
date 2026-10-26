import WebKit
import XCTest
@testable import Lilo

/// Covers `ProcessManagerBridgeHandler.terminateProcess`'s guard ladder and the process id
/// resolution behind it. The kill syscall is a spy closure and the pid-only diagnostics provider is
/// injected, so a real `BrowserStateStore` with a live engine yields deterministic process pids.
@MainActor
final class ProcessManagerBridgeHandlerTests: XCTestCase {

    private final class KillSpy {
        private(set) var killedPids: [Int32] = []
        func kill(_ pid: Int32) -> Int32 {
            killedPids.append(pid)
            return 0
        }
    }

    private func makeHandler(
        store: BrowserStateStore,
        windowController: MainWindowController,
        killSpy: KillSpy,
        diagnostics: @escaping @MainActor @Sendable (WKWebViewTab) -> WebViewProcessDiagnostics
    ) -> ProcessManagerBridgeHandler {
        windowController.bridgeRouter = BridgeRouter(chromeWebView: windowController.chromeWebView)
        return ProcessManagerBridgeHandler(
            browserStateStore: store,
            tabManager: windowController.tabManager,
            windowController: windowController,
            bridgeRouter: windowController.bridgeRouter,
            killProcess: { killSpy.kill($0) },
            identityDiagnostics: diagnostics
        )
    }

    /// A store with one space holding one live engine, so the snapshot builder has a webview to
    /// hand to the injected diagnostics provider.
    private func makeStoreWithEngine() -> (store: BrowserStateStore, engine: WKWebViewTab) {
        let spaceId = UUID()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)),
                engines: [UUID(): engine]
            )
        )
        return (store, engine)
    }

    private func terminateMessage(_ payload: [String: Any]) -> BridgeMessage {
        BridgeMessage(dictionary: ["action": "terminateProcess", "payload": payload])!
    }

    // MARK: - Guard ladder

    func test_terminateProcess_unconfirmed_doesNotKill() async {
        let (store, engine) = makeStoreWithEngine()
        defer { engine.teardown() }
        let spy = KillSpy()
        let handler = makeHandler(store: store, windowController: MainWindowController(), killSpy: spy) { _ in
            WebViewProcessDiagnostics(webProcessIdentifier: 4242)
        }

        _ = await handler.handle(message: terminateMessage(["processId": "webContent-4242"]))

        XCTAssertTrue(spy.killedPids.isEmpty)
    }

    func test_terminateProcess_unknownProcess_doesNotKill() async {
        let (store, engine) = makeStoreWithEngine()
        defer { engine.teardown() }
        let spy = KillSpy()
        let handler = makeHandler(store: store, windowController: MainWindowController(), killSpy: spy) { _ in
            WebViewProcessDiagnostics(webProcessIdentifier: 4242)
        }

        _ = await handler.handle(message: terminateMessage(["confirmed": true, "processId": "webContent-999999"]))

        XCTAssertTrue(spy.killedPids.isEmpty)
    }

    func test_terminateProcess_ownPid_isRefused() async {
        let (store, engine) = makeStoreWithEngine()
        defer { engine.teardown() }
        let ownPid = Int(getpid())
        let spy = KillSpy()
        let handler = makeHandler(store: store, windowController: MainWindowController(), killSpy: spy) { _ in
            WebViewProcessDiagnostics(webProcessIdentifier: ownPid)
        }

        _ = await handler.handle(message: terminateMessage(["confirmed": true, "processId": "webContent-\(ownPid)"]))

        XCTAssertTrue(spy.killedPids.isEmpty)
    }

    // MARK: - resolveProcess

    func test_terminateProcess_processId_matchesOnlyThatKindAndPid() async {
        let (store, engine) = makeStoreWithEngine()
        defer { engine.teardown() }
        let spy = KillSpy()
        let handler = makeHandler(store: store, windowController: MainWindowController(), killSpy: spy) { _ in
            WebViewProcessDiagnostics(webProcessIdentifier: 4242, gpuProcessIdentifier: 4343)
        }

        _ = await handler.handle(message: terminateMessage(["confirmed": true, "processId": "gpu-4343"]))
        XCTAssertEqual(spy.killedPids, [4343])

        // Mismatched kind for an existing pid resolves nothing.
        _ = await handler.handle(message: terminateMessage(["confirmed": true, "processId": "gpu-4242"]))
        XCTAssertEqual(spy.killedPids, [4343])
    }

    func testCPUTimeMatchesKernelAccountingForOwnProcess() throws {
        var spin = 0.0
        for index in 0..<20_000_000 { spin += Double(index).squareRoot() }
        XCTAssertGreaterThan(spin, 0)
        let info = try XCTUnwrap(ProcessTaskInfoSampler.taskInfo(pid: Int(getpid())))
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let rusageNanoseconds = (Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1e9)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1e3
        let sampled = Double(ProcessTaskInfoSampler.cpuNanoseconds(info))
        XCTAssertEqual(sampled / rusageNanoseconds, 1, accuracy: 0.1, "CPU time must be in nanoseconds, not Mach ticks")
    }

    func testPhysicalFootprintCountsOwnProcessAndRejectsUnknownPid() throws {
        let footprint = try XCTUnwrap(ProcessTaskInfoSampler.physicalFootprint(pid: Int(getpid())))
        XCTAssertGreaterThan(footprint, 1 << 20)
        XCTAssertNil(ProcessTaskInfoSampler.physicalFootprint(pid: Int(Int32.max)))
    }
}
