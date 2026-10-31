import AppKit
import PDFKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class WKWebViewTabPrintTests: XCTestCase {
    /// Prints `tab` to a PDF as the print panel's Save as PDF does, and returns each page's text.
    private func printedPages(of tab: WKWebViewTab, in window: NSWindow) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("print-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let printInfo = try XCTUnwrap(NSPrintInfo.shared.copy() as? NSPrintInfo)
        printInfo.jobDisposition = .save
        // A4, whatever the machine's default paper: the page count depends on it.
        printInfo.paperSize = NSSize(width: 595, height: 842)
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = tab.wkWebView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let done = expectation(description: "printed")
        // Without a panel, the operation ends on its own thread.
        let ended = PrintEnd { done.fulfill() }
        operation.runModal(for: window, delegate: ended, didRun: #selector(PrintEnd.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        await fulfillment(of: [done], timeout: 20)
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
    }

    func testPrintedPagesNumberTheirFooterAndDropHeadersAndFootersWhenAskedTo() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "PrintHeadersAndFooters")
        addTeardownBlock { @MainActor in defaults.set(saved, forKey: "PrintHeadersAndFooters") }
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.view
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            tab.teardown()
        }
        tab.wkWebView.loadHTMLString("<title>Boarding pass</title><p style='height: 1500px'>Seat 12A</p><p>Gate 4</p>",
                                     baseURL: URL(string: "https://tickets.example/"))
        let loaded = await pollUntil(timeout: 5) { (try? await tab.wkWebView.evaluateJavaScript("document.readyState === 'complete' && document.title")) as? String == "Boarding pass" }
        XCTAssertTrue(loaded)

        defaults.set(true, forKey: "PrintHeadersAndFooters")
        let framed = try await printedPages(of: tab, in: window)
        XCTAssertEqual(framed.count, 2)
        XCTAssertTrue(framed.first?.contains("Boarding pass") == true)
        XCTAssertTrue(framed.first?.contains("1/2") == true, "the footer numbers each page, as in Chrome")
        XCTAssertTrue(framed.last?.contains("2/2") == true)

        defaults.set(false, forKey: "PrintHeadersAndFooters")
        let bare = try await printedPages(of: tab, in: window)
        XCTAssertFalse(bare.joined().contains("Boarding pass"))
        XCTAssertFalse(bare.joined().contains("tickets.example"))
        XCTAssertTrue(bare.first?.contains("Seat 12A") == true)
    }
}

private final class PrintEnd: NSObject, @unchecked Sendable {
    private let ended: () -> Void
    init(_ ended: @escaping () -> Void) { self.ended = ended }
    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) { ended() }
}
