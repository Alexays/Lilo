import OSLog
import WebKit
import XCTest
@testable import Lilo

/// Private browsing leaves no line in the navigation log, whose hosts are private data anyway.
@MainActor
final class WKWebViewTabLoggingTests: XCTestCase {
    func testPrivateBrowsingLeavesNoNavigationLine() async throws {
        let server = try await TinyHTTPServer(index: "<p>visited</p>")
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
        let factory = WKEngineFactory()
        // Followed live: info entries live only in memory, where the parallel suite's logging evicts them
        // before a later OSLogStore read.
        let stream = Process()
        stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        stream.arguments = [
            "stream", "--level", "info", "--style", "compact", "--predicate",
            "processIdentifier == \(getpid()) AND subsystem == '\(Logger.subsystem)' AND category == 'navigation'"
        ]
        let pipe = Pipe()
        stream.standardOutput = pipe
        let output = OSAllocatedUnfairLock(initialState: "")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(bytes: handle.availableData, encoding: .utf8) ?? ""
            output.withLock { $0 += text }
        }
        try stream.run()
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            stream.terminate()
        }
        let logger = Logger(liloCategory: "navigation")
        /// Logs `marker` until the stream shows it, and returns what the stream showed before it.
        func streamed(until marker: String) async -> String? {
            let shown = await pollUntil(timeout: 30) {
                logger.info("\(marker, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(200))
                return output.withLock { $0.contains(marker) }
            }
            return shown ? output.withLock { text in text.range(of: marker).map { String(text[..<$0.lowerBound]) } } : nil
        }
        let shownStart = await streamed(until: "test-start-\(UUID().uuidString)")
        let started = try XCTUnwrap(shownStart, "the log stream shows nothing")

        let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
        tab.loadURL(url)
        _ = await pollUntil { tab.wkWebView.url != nil && !tab.wkWebView.isLoading }
        tab.teardown()
        // A process's entries stream in order: whatever the visit logged shows before this marker.
        let shownEnd = await streamed(until: "test-end-\(UUID().uuidString)")
        let visited = try XCTUnwrap(shownEnd, "the log stream stopped")

        XCTAssertFalse(visited.dropFirst(started.count).contains("host="), "private browsing logs no navigation")
    }
}
