import WebKit
import XCTest
@testable import Lilo

/// Omnibox request/reply correlation: a keyword needs a trailing space, a reply must come from the owning extension,
/// superseded replies are dropped, and cancel purges pending requests.
@MainActor
final class OmniboxBridgeHandlerTests: XCTestCase {

    private var router: BridgeRouter!
    private var handler: OmniboxBridgeHandler!
    /// (event, args, extensionId) tuples emitted toward the extension.
    private var emitted: [(event: String, args: [Any], extensionId: String)] = []
    /// `omniboxSuggestions` payloads forwarded to the chrome UI.
    private var forwarded: [[String: Any]] = []

    override func setUp() {
        super.setUp()
        router = BridgeRouter(chromeWebView: WKWebView())
        emitted = []
        forwarded = []
        router.javaScriptSink = { [weak self] _, arguments, completion in
            if let message = arguments["message"] as? [String: Any],
               message["event"] as? String == "omniboxSuggestions" {
                self?.forwarded.append(message)
            }
            completion()
        }
        handler = OmniboxBridgeHandler(
            resolveKeywordOwner: { keyword in keyword == "kw" ? "ext1" : nil },
            emitToExtension: { [weak self] event, args, id in self?.emitted.append((event, args, id)) },
            bridgeRouter: router
        )
    }

    override func tearDown() {
        handler = nil
        router = nil
        super.tearDown()
    }

    /// Address-bar actions reach the handler; extension replies (`omnibox.*`) arrive through the gap relay.
    private func handle(_ action: String, _ payload: [String: Any]) async -> Any? {
        let message = BridgeMessage(dictionary: ["action": action, "payload": payload])!
        let result: Any?
        if action.hasPrefix("omnibox.") {
            let relay = OmniboxGapRelay()
            relay.add(handler)
            result = await relay.handle(message)
        } else {
            result = await handler.handle(message: message)
        }
        await shipBridgeSends()
        return result
    }

    /// Raw bridge sends ship at the end of the main-loop turn: a main-queue hop runs after that flush.
    private func shipBridgeSends() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// Types "<query>" in session `sessionId` and returns the requestId emitted to the extension.
    private func inputChanged(sessionId: String, query: String) async -> String? {
        _ = await handle("omniboxInputChanged", ["sessionId": sessionId, "query": query])
        guard let last = emitted.last, last.event == "onInputChanged" else { return nil }
        return last.args.first as? String
    }

    // MARK: - Keyword resolution

    func test_ownerRequiresTrailingSpaceAfterKeyword() async {
        _ = await handle("omniboxInputChanged", ["sessionId": "s1", "query": "kw"])
        XCTAssertTrue(emitted.isEmpty, "a bare keyword without a trailing space must not activate the omnibox")

        _ = await handle("omniboxInputChanged", ["sessionId": "s1", "query": "kw foo"])
        XCTAssertEqual(emitted.last?.event, "onInputChanged")
        XCTAssertEqual(emitted.last?.extensionId, "ext1")
        XCTAssertEqual(emitted.last?.args.last as? String, "foo")
    }

    // MARK: - suggest() replies

    func test_replyFromWrongExtension_isRejected() async {
        let requestId = await inputChanged(sessionId: "s1", query: "kw foo")
        XCTAssertNotNil(requestId)

        let result = await handle("omnibox.sendSuggestions", [
            "extensionId": "ext2", "requestId": requestId ?? "", "suggestions": [[String: Any]]()
        ])
        XCTAssertNotNil(result as? BridgeError)
        XCTAssertTrue(forwarded.isEmpty)

        // The pending request is not consumed by the unauthorized reply; the owner can still answer.
        let ownerResult = await handle("omnibox.sendSuggestions", [
            "extensionId": "ext1", "requestId": requestId ?? "", "suggestions": [[String: Any]]()
        ])
        XCTAssertNil(ownerResult as? BridgeError)
        XCTAssertEqual(forwarded.count, 1)
    }

    func test_supersededRequestId_isDroppedSilently() async {
        let staleRequestId = await inputChanged(sessionId: "s1", query: "kw f")
        let latestRequestId = await inputChanged(sessionId: "s1", query: "kw fo")

        let staleResult = await handle("omnibox.sendSuggestions", [
            "extensionId": "ext1", "requestId": staleRequestId ?? "", "suggestions": [[String: Any]]()
        ])
        XCTAssertNil(staleResult as? BridgeError, "a stale reply is dropped, not an error")
        XCTAssertTrue(forwarded.isEmpty, "a stale reply must not reach the UI")

        _ = await handle("omnibox.sendSuggestions", [
            "extensionId": "ext1", "requestId": latestRequestId ?? "", "suggestions": [[String: Any]]()
        ])
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded.first?["sessionId"] as? String, "s1")
    }

    func test_aSessionKeepsOnlyItsLatestSupersededRequest() async {
        let oldest = await inputChanged(sessionId: "s1", query: "kw f")
        let superseded = await inputChanged(sessionId: "s1", query: "kw fo")
        _ = await inputChanged(sessionId: "s1", query: "kw foo")

        XCTAssertFalse(handler.tracks(requestId: oldest ?? ""))
        XCTAssertTrue(handler.tracks(requestId: superseded ?? ""))
    }

    func test_enteringEndsTheSession() async {
        let requestId = await inputChanged(sessionId: "s1", query: "kw foo")

        _ = await handle("omniboxInputEntered", ["sessionId": "s1", "query": "kw foo"])

        XCTAssertEqual(emitted.last?.event, "onInputEntered")
        XCTAssertFalse(handler.tracks(requestId: requestId ?? ""), "an entered session keeps no request")
    }

    func test_cancelPurgesPendingRequests() async {
        let requestId = await inputChanged(sessionId: "s1", query: "kw foo")
        _ = await handle("omniboxInputCancelled", ["sessionId": "s1"])
        XCTAssertEqual(emitted.last?.event, "onInputCancelled")

        let result = await handle("omnibox.sendSuggestions", [
            "extensionId": "ext1", "requestId": requestId ?? "", "suggestions": [[String: Any]]()
        ])
        XCTAssertNotNil(result as? BridgeError, "a reply to a cancelled session's request must be unknown")
        XCTAssertTrue(forwarded.isEmpty)
    }

    // MARK: - Several windows

    func test_relayRoutesEachReplyToTheWindowThatAsked() async {
        let otherRouter = BridgeRouter(chromeWebView: WKWebView())
        var otherForwarded: [[String: Any]] = []
        otherRouter.javaScriptSink = { _, arguments, completion in
            if let message = arguments["message"] as? [String: Any],
               message["event"] as? String == "omniboxSuggestions" {
                otherForwarded.append(message)
            }
            completion()
        }
        let otherHandler = OmniboxBridgeHandler(
            resolveKeywordOwner: { $0 == "kw" ? "ext1" : nil },
            emitToExtension: { _, _, _ in },
            bridgeRouter: otherRouter
        )
        let relay = OmniboxGapRelay()
        relay.add(handler)
        relay.add(otherHandler)

        // Both windows number their sessions alike; the request id tells them apart.
        let requestId = await inputChanged(sessionId: "omni-1", query: "kw foo")
        _ = await otherHandler.handle(
            message: BridgeMessage(dictionary: ["action": "omniboxInputChanged", "payload": ["sessionId": "omni-1", "query": "kw bar"]])!
        )
        let reply = BridgeMessage(dictionary: ["action": "omnibox.sendSuggestions", "payload": [
            "extensionId": "ext1", "requestId": requestId ?? "", "suggestions": [[String: Any]]()
        ]])!
        let result = await relay.handle(reply)
        await shipBridgeSends()

        XCTAssertNil(result as? BridgeError)
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertTrue(otherForwarded.isEmpty)
    }

    func test_deletedSuggestionReachesTheKeywordOwner() async {
        _ = await handle("omniboxDeleteSuggestion", ["query": "kw foo", "text": "Foo result"])
        _ = await handle("omniboxDeleteSuggestion", ["query": "other foo", "text": "ignored"])

        XCTAssertEqual(emitted.map(\.event), ["onDeleteSuggestion"])
        XCTAssertEqual(emitted.first?.args as? [String], ["Foo result"])
        XCTAssertEqual(emitted.first?.extensionId, "ext1")
    }
}
