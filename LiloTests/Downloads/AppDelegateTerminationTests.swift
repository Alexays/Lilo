import XCTest
@testable import Lilo

@MainActor
final class AppDelegateTerminationTests: XCTestCase {

    func testNothingRunningTerminatesNow() {
        let delegate = AppDelegate()
        delegate.confirmQuit = { _, _ in
            XCTFail("confirmation must not be shown when nothing would be lost")
            return false
        }
        XCTAssertEqual(delegate.terminationReply(activeDownloads: 0, busyCommands: [], systemInitiated: false), .terminateNow)
    }

    func testActiveDownloadsConfirmedQuitTerminatesLater() {
        let delegate = AppDelegate()
        var asked: (Int, [String])?
        delegate.confirmQuit = { downloads, commands in
            asked = (downloads, commands)
            return true
        }
        XCTAssertEqual(delegate.terminationReply(activeDownloads: 2, busyCommands: [], systemInitiated: false), .terminateLater)
        XCTAssertEqual(asked?.0, 2)
        XCTAssertEqual(asked?.1, [])
    }

    func testActiveDownloadsDeclinedQuitCancels() {
        let delegate = AppDelegate()
        delegate.confirmQuit = { _, _ in false }
        XCTAssertEqual(delegate.terminationReply(activeDownloads: 1, busyCommands: [], systemInitiated: false), .terminateCancel)
    }

    func testBusyTerminalsAskAndTerminateNowOnceConfirmed() {
        let delegate = AppDelegate()
        var askedCommands: [String]?
        delegate.confirmQuit = { _, commands in
            askedCommands = commands
            return true
        }
        XCTAssertEqual(delegate.terminationReply(activeDownloads: 0, busyCommands: ["claude", ""], systemInitiated: false), .terminateNow)
        XCTAssertEqual(askedCommands, ["claude", ""])
    }

    func testBusyTerminalsDeclinedQuitCancels() {
        let delegate = AppDelegate()
        delegate.confirmQuit = { _, _ in false }
        XCTAssertEqual(delegate.terminationReply(activeDownloads: 0, busyCommands: ["npm run dev"], systemInitiated: false), .terminateCancel)
    }

    func testLogoutQuitsWithoutAsking() {
        let delegate = AppDelegate()
        delegate.confirmQuit = { _, _ in
            XCTFail("a logout, restart or shutdown must not wait on a question")
            return false
        }
        XCTAssertEqual(delegate.terminationReply(activeDownloads: 0, busyCommands: ["claude"], systemInitiated: true), .terminateNow)
        XCTAssertEqual(delegate.terminationReply(activeDownloads: 1, busyCommands: ["claude"], systemInitiated: true), .terminateLater)
    }
}
