import XCTest
@testable import Lilo

@MainActor
final class TabShareBridgeHandlerTests: XCTestCase {

    private func handle(_ payload: [String: Any], into resolutions: inout [(String, TabSharePickerChoice)]) async {
        var captured: [(String, TabSharePickerChoice)] = []
        let box = { (id: String, choice: TabSharePickerChoice) in captured.append((id, choice)) }
        let handler = TabShareBridgeHandler(resolve: box)
        _ = await handler.handle(message: BridgeMessage(dictionary: ["action": "tabShare.resolve", "payload": payload])!)
        resolutions.append(contentsOf: captured)
    }

    func testResolvesTabChoiceWithId() async {
        let tabId = UUID()
        var resolutions: [(String, TabSharePickerChoice)] = []
        await handle(["requestId": "r1", "choice": "tab", "tabId": tabId.uuidString], into: &resolutions)

        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions.first?.0, "r1")
        guard case .tab(let resolved) = resolutions.first?.1 else { return XCTFail("expected .tab") }
        XCTAssertEqual(resolved, tabId)
    }

    func testTabChoiceWithBadIdResolvesCancel() async {
        var resolutions: [(String, TabSharePickerChoice)] = []
        await handle(["requestId": "r2", "choice": "tab", "tabId": "not-a-uuid"], into: &resolutions)
        guard case .cancel = resolutions.first?.1 else { return XCTFail("expected .cancel") }
    }

    func testSystemAndUnknownChoices() async {
        var resolutions: [(String, TabSharePickerChoice)] = []
        await handle(["requestId": "r3", "choice": "system"], into: &resolutions)
        await handle(["requestId": "r4", "choice": "bogus"], into: &resolutions)

        guard case .system = resolutions[0].1 else { return XCTFail("expected .system") }
        guard case .cancel = resolutions[1].1 else { return XCTFail("expected .cancel") }
    }
}
