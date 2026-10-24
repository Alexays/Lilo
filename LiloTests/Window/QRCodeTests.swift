import AppKit
import CoreImage
import XCTest
@testable import Lilo

@MainActor
final class QRCodeTests: XCTestCase {
    func testTheCodeScansBackToThePageAddress() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a/page?q=lilo#top"))
        let image = try XCTUnwrap(MainWindowController.qrCode(for: url, side: 220))
        XCTAssertEqual(image.size, NSSize(width: 220, height: 220))
        XCTAssertEqual(image.accessibilityDescription, String(format: "QR code for %@".localized, "example.com"), "VoiceOver names the code")

        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let decoded = detector.features(in: CIImage(cgImage: cgImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(decoded, [url.absoluteString])
    }
}
