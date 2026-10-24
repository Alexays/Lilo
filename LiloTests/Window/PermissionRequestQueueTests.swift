import GRDB
import XCTest
@testable import Lilo

@MainActor
final class PermissionRequestQueueTests: XCTestCase {
    private var wc: MainWindowController!
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        wc = MainWindowController(context: browserContext.context)
        wc.bridgeRouter = BridgeRouter(chromeWebView: wc.chromeWebView)
    }

    override func tearDown() {
        wc = nil
        browserContext.tearDown()
        browserContext = nil
    }

    func testConcurrentRequestsQueueAndResolveIndependently() throws {
        let tabId = UUID()
        var cameraAnswer: Bool?
        var microphoneAnswer: Bool?

        wc.enqueuePermissionRequest(tabId: tabId, type: "camera", origin: "https://call.example") { cameraAnswer = $0 }
        wc.enqueuePermissionRequest(tabId: tabId, type: "microphone", origin: "https://call.example") { microphoneAnswer = $0 }

        XCTAssertEqual(wc.pendingPermissionRequests.count, 2, "A second request must queue, not overwrite the first")
        XCTAssertNil(cameraAnswer)
        XCTAssertNil(microphoneAnswer)

        let cameraId = try XCTUnwrap(wc.pendingPermissionRequests.first?.id)
        let microphoneId = try XCTUnwrap(wc.pendingPermissionRequests.last?.id)

        wc.resolvePermissionRequest(requestId: cameraId, granted: true)
        XCTAssertEqual(cameraAnswer, true)
        XCTAssertNil(microphoneAnswer, "The queued request must wait for its own answer")

        wc.resolvePermissionRequest(requestId: microphoneId, granted: false)
        XCTAssertEqual(microphoneAnswer, false)
        XCTAssertTrue(wc.pendingPermissionRequests.isEmpty)

        XCTAssertEqual(wc.context.sitePermissionStore.decision(forOrigin: "https://call.example", type: "camera"), true)
        XCTAssertEqual(wc.context.sitePermissionStore.decision(forOrigin: "https://call.example", type: "microphone"), false)
    }

    func testTabCloseDeniesItsPendingRequestsOnly() throws {
        let closingTab = UUID()
        let otherTab = UUID()
        var closedAnswer: Bool?
        var otherAnswer: Bool?

        wc.enqueuePermissionRequest(tabId: closingTab, type: "camera", origin: "https://a.example") { closedAnswer = $0 }
        wc.enqueuePermissionRequest(tabId: otherTab, type: "geolocation", origin: "https://b.example") { otherAnswer = $0 }

        wc.denyPermissionRequests(forTab: closingTab)

        XCTAssertEqual(closedAnswer, false)
        XCTAssertNil(otherAnswer)
        XCTAssertEqual(wc.pendingPermissionRequests.count, 1)
        XCTAssertEqual(wc.pendingPermissionRequests.first?.tabId, otherTab)
        XCTAssertNil(wc.context.sitePermissionStore.decision(forOrigin: "https://a.example", type: "camera"),
                     "A close-time denial must not be stored as a site decision")

        wc.resolvePermissionRequest(requestId: try XCTUnwrap(wc.pendingPermissionRequests.first?.id), granted: true)
        XCTAssertEqual(otherAnswer, true)
    }

    func testDismissedRequestDeniesWithoutStoringADecision() throws {
        var answer: Bool?
        wc.enqueuePermissionRequest(tabId: UUID(), type: "geolocation", origin: "https://maps.example") { answer = $0 }

        wc.resolvePermissionRequest(requestId: try XCTUnwrap(wc.pendingPermissionRequests.first?.id), granted: false, remember: false)

        XCTAssertEqual(answer, false)
        XCTAssertTrue(wc.pendingPermissionRequests.isEmpty)
        XCTAssertNil(wc.context.sitePermissionStore.decision(forOrigin: "https://maps.example", type: "geolocation"),
                     "A dismissal denies for now: the site may ask again")
    }

    func testTimeoutDeniesRequest() {
        wc.permissionRequestTimeout = 0.05
        let denied = expectation(description: "timeout denies the request")

        wc.enqueuePermissionRequest(tabId: UUID(), type: "notifications", origin: "https://slow.example") { granted in
            XCTAssertFalse(granted)
            denied.fulfill()
        }

        wait(for: [denied], timeout: 2)
        XCTAssertTrue(wc.pendingPermissionRequests.isEmpty)
    }

    func testResolveAfterFinishIsNoOp() throws {
        var answers: [Bool] = []
        wc.enqueuePermissionRequest(tabId: UUID(), type: "camera", origin: "https://a.example") { answers.append($0) }
        let id = try XCTUnwrap(wc.pendingPermissionRequests.first?.id)

        wc.resolvePermissionRequest(requestId: id, granted: true)
        wc.resolvePermissionRequest(requestId: id, granted: false)

        XCTAssertEqual(answers, [true], "Each completion handler must run exactly once")
    }
}
