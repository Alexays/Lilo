import XCTest

final class WKWebViewTabSourceTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Lilo/Engine/WKWebViewTab.swift"), encoding: .utf8)
    }

    /// Asserts on the helper name, not `DispatchQueue.main.async`, which auth, permission, pointer-lock and focus handlers
    /// use legitimately.
    func testNavigationCallbacksUseSynchronousMainActorDispatch() throws {
        let src = try source()
        XCTAssertFalse(src.contains("dispatchToMain"),
                       "WKWebViewTab nav/KVO callbacks should run synchronously on the already-main-thread WebKit callback: replace dispatchToMain with onMain { } (MainActor.assumeIsolated)")
    }
}
