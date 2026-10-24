import XCTest
@testable import Lilo

@MainActor
final class StartupBackgroundWorkTests: XCTestCase {

    func testRunBlockingExecutesOffMainThread() async throws {
        let executedOnMainThread = try await BrowserContext.StartupBackgroundWork.runBlocking {
            Thread.isMainThread
        }

        XCTAssertFalse(executedOnMainThread)
    }
}
