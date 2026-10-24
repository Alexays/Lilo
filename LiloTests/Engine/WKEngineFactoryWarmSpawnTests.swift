import XCTest

/// The warm-pool view must spawn its process without loading about:blank, which would commit a back-forward entry the
/// back-swipe lands on. `WKEngineFactoryWarmHistoryTests` covers both halves functionally.
final class WKEngineFactoryWarmSpawnTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Lilo/Engine/WKEngineFactory.swift"), encoding: .utf8)
    }

    func testWarmPoolDoesNotCommitAboutBlankNavigation() throws {
        let src = try source()
        XCTAssertFalse(src.contains(#"URL(string: "about:blank")"#),
                       "prepareWarm must not load about:blank: a committed about:blank lands in the back-forward list, so the back-swipe gesture navigates onto a blank, unreloadable page")
    }

    func testWarmPoolSpawnsProcessWithoutANavigation() throws {
        let src = try source()
        XCTAssertTrue(src.contains("evaluateJavaScript"),
                      "prepareWarm must still pre-spawn its WebContent process: evaluateJavaScript forces the launch against the initial empty document without committing a navigation")
    }

    func testNoDeprecatedProcessPoolPrewarm() throws {
        let appDelegate = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Lilo/App/AppDelegate.swift"), encoding: .utf8)
        XCTAssertFalse(appDelegate.contains("_warmInitialProcess"),
                       "the WKProcessPool _warmInitialProcess prewarm is inert on macOS 12+ and not data-store-matched: use the warm pool's evaluateJavaScript spawn instead")
    }
}
