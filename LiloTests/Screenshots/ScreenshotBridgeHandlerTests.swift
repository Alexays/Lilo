import AppKit
import os
import XCTest
@testable import Lilo

@MainActor
final class ScreenshotBridgeHandlerTests: XCTestCase {

    private func makeMessage(action: String, payload: [String: Any]) -> BridgeMessage {
        BridgeMessage(dictionary: ["action": action, "payload": payload])!
    }

    // "PNG" => UE5H
    private let validDataURL = "data:image/png;base64,UE5H"

    func test_handledActions() {
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp") },
            writeFile: { _, _ in }, presentSaveAs: { _, _ in }, copyToPasteboard: { _ in },
            onSaved: { _ in }, onError: { _ in }, capture: { _ in nil }, discardCapture: { _ in }
        )
        XCTAssertEqual(
            handler.handledActions,
            ["screenshot.saveDefault", "screenshot.saveAs", "screenshot.copy", "screenshot.cancel"]
        )
    }

    func test_saveDefault_writesDecodedBytesToDownloadsFolder_andReportsPath() async {
        let written = OSAllocatedUnfairLock<(Data, URL)?>(initialState: nil)
        var savedPath: String?
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { data, url in written.withLock { $0 = (data, url) } },
            presentSaveAs: { _, _ in },
            copyToPasteboard: { _ in },
            onSaved: { savedPath = $0 },
            onError: { _ in }, capture: { _ in nil }, discardCapture: { _ in }
        )
        _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveDefault",
            payload: ["dataURL": validDataURL, "filename": "shot.png"]
        ))
        let write = written.withLock { $0 }
        XCTAssertEqual(write.map { String(decoding: $0.0, as: UTF8.self) }, "PNG")
        XCTAssertEqual(write?.1, URL(fileURLWithPath: "/tmp/dl/shot.png"))
        XCTAssertEqual(savedPath, "/tmp/dl/shot.png")
    }

    func test_saveDefault_backToBackSameFilename_writesTwoDifferentFiles() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let written = OSAllocatedUnfairLock<[URL]>(initialState: [])
        var savedPaths: [String] = []
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { folder },
            writeFile: { _, url in
                written.withLock { $0.append(url) }
                // Hold the first write open until the second save has picked its name.
                let deadline = Date().addingTimeInterval(2)
                while written.withLock({ $0.count }) < 2, Date() < deadline { usleep(1_000) }
            },
            presentSaveAs: { _, _ in },
            copyToPasteboard: { _ in },
            onSaved: { savedPaths.append($0) },
            onError: { _ in }, capture: { _ in nil }, discardCapture: { _ in }
        )
        let first = Task { _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveDefault", payload: ["dataURL": validDataURL, "filename": "shot.png"]
        )) }
        let second = Task { _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveDefault", payload: ["dataURL": validDataURL, "filename": "shot.png"]
        )) }
        await first.value
        await second.value

        let urls = written.withLock { $0 }
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(Set(urls).count, 2)
        XCTAssertEqual(Set(savedPaths), Set(urls.map(\.path)))
    }

    func test_saveDefault_badDataURL_reportsError_doesNotWrite() async {
        let wrote = OSAllocatedUnfairLock(initialState: false)
        var errored = false
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { _, _ in wrote.withLock { $0 = true } },
            presentSaveAs: { _, _ in },
            copyToPasteboard: { _ in },
            onSaved: { _ in },
            onError: { _ in errored = true }, capture: { _ in nil }, discardCapture: { _ in }
        )
        _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveDefault",
            payload: ["dataURL": "data:image/png;base64,@@@", "filename": "shot.png"]
        ))
        XCTAssertFalse(wrote.withLock { $0 })
        XCTAssertTrue(errored)
    }

    func test_saveAs_invokesPresentSaveAs_withFilenameAndDecodedData() async {
        var presented: (String, Data)?
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { _, _ in },
            presentSaveAs: { name, data in presented = (name, data) },
            copyToPasteboard: { _ in },
            onSaved: { _ in },
            onError: { _ in }, capture: { _ in nil }, discardCapture: { _ in }
        )
        _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveAs",
            payload: ["dataURL": validDataURL, "filename": "shot.png"]
        ))
        XCTAssertEqual(presented?.0, "shot.png")
        XCTAssertEqual(presented.map { String(decoding: $0.1, as: UTF8.self) }, "PNG")
    }

    func test_saveAs_badDataURL_doesNotPresent() async {
        var presented = false
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { _, _ in },
            presentSaveAs: { _, _ in presented = true },
            copyToPasteboard: { _ in },
            onSaved: { _ in }, onError: { _ in }, capture: { _ in nil }, discardCapture: { _ in }
        )
        _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveAs",
            payload: ["dataURL": "data:image/png;base64,@@@", "filename": "shot.png"]
        ))
        XCTAssertFalse(presented)
    }

    func test_copy_passesDecodedBytesToPasteboard() async {
        var copied: Data?
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { _, _ in },
            presentSaveAs: { _, _ in },
            copyToPasteboard: { copied = $0 },
            onSaved: { _ in }, onError: { _ in }, capture: { _ in nil }, discardCapture: { _ in }
        )
        _ = await handler.handle(message: makeMessage(
            action: "screenshot.copy", payload: ["dataURL": validDataURL]
        ))
        XCTAssertEqual(copied.map { String(decoding: $0, as: UTF8.self) }, "PNG")
    }

    func test_saveDefault_withoutDataURL_writesTheHeldCaptureCropped_andReleasesIt() async throws {
        let png = try XCTUnwrap(Self.png(width: 40, height: 30))
        let written = OSAllocatedUnfairLock<Data?>(initialState: nil)
        var discarded: [String] = []
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { data, _ in written.withLock { $0 = data } },
            presentSaveAs: { _, _ in },
            copyToPasteboard: { _ in },
            onSaved: { _ in }, onError: { _ in },
            capture: { $0 == "capture-1" ? png : nil },
            discardCapture: { discarded.append($0) }
        )
        _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveDefault",
            payload: ["id": "capture-1", "crop": ["x": 5.0, "y": 10.0, "w": 20.0, "h": 15.0], "filename": "shot.png"]
        ))
        let image = try XCTUnwrap(written.withLock { $0 }.flatMap { NSBitmapImageRep(data: $0) })
        XCTAssertEqual(image.pixelsWide, 20)
        XCTAssertEqual(image.pixelsHigh, 15)
        XCTAssertEqual(discarded, ["capture-1"])
    }

    func test_saveDefault_withoutCrop_writesTheHeldCaptureAsIs() async throws {
        let png = try XCTUnwrap(Self.png(width: 40, height: 30))
        let written = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { data, _ in written.withLock { $0 = data } },
            presentSaveAs: { _, _ in },
            copyToPasteboard: { _ in },
            onSaved: { _ in }, onError: { _ in },
            capture: { _ in png }, discardCapture: { _ in }
        )
        _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveDefault", payload: ["id": "capture-1", "filename": "shot.png"]
        ))
        XCTAssertEqual(written.withLock { $0 }, png)
    }

    func test_saveDefault_releasedCapture_reportsError_doesNotWrite() async {
        let wrote = OSAllocatedUnfairLock(initialState: false)
        var errored = false
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { _, _ in wrote.withLock { $0 = true } },
            presentSaveAs: { _, _ in },
            copyToPasteboard: { _ in },
            onSaved: { _ in }, onError: { _ in errored = true },
            capture: { _ in nil }, discardCapture: { _ in }
        )
        _ = await handler.handle(message: makeMessage(
            action: "screenshot.saveDefault", payload: ["id": "gone", "filename": "shot.png"]
        ))
        XCTAssertFalse(wrote.withLock { $0 })
        XCTAssertTrue(errored)
    }

    func test_cancel_releasesTheCapture() async {
        var discarded: [String] = []
        let handler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { URL(fileURLWithPath: "/tmp/dl") },
            writeFile: { _, _ in }, presentSaveAs: { _, _ in }, copyToPasteboard: { _ in },
            onSaved: { _ in }, onError: { _ in },
            capture: { _ in nil }, discardCapture: { discarded.append($0) }
        )
        _ = await handler.handle(message: makeMessage(action: "screenshot.cancel", payload: ["id": "capture-1"]))
        XCTAssertEqual(discarded, ["capture-1"])
    }

    private static func png(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().flatMap(ScreenshotImageCodec.pngData)
    }
}
