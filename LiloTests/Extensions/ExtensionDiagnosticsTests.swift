import XCTest
import WebKit
@testable import Lilo

final class ExtensionDiagnosticsTests: XCTestCase {
    /// Only a background that failed to load is worth a reload: a missing asset or a script error from a
    /// running worker repeats on every start.
    func testOnlyABackgroundLoadFailureWarrantsARevive() {
        let resourceNotFound = NSError(
            domain: WKWebExtension.errorDomain,
            code: WKWebExtension.Error.resourceNotFound.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Unable to find \"argon2.wasm\" in the extension's resources."]
        )
        let scriptError = NSError(domain: "WKWebExtensionContextErrorDomain", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "TypeError: undefined is not an object (evaluating 't.frameId')"])
        let backgroundFailed = NSError(domain: "WKWebExtensionContextErrorDomain", code: 6)

        XCTAssertFalse(ExtensionDiagnostics.errorsWarrantBackgroundRevive([]))
        XCTAssertFalse(ExtensionDiagnostics.errorsWarrantBackgroundRevive([resourceNotFound]))
        XCTAssertFalse(ExtensionDiagnostics.errorsWarrantBackgroundRevive([scriptError]))
        XCTAssertTrue(ExtensionDiagnostics.errorsWarrantBackgroundRevive([backgroundFailed]))
        XCTAssertTrue(ExtensionDiagnostics.errorsWarrantBackgroundRevive([resourceNotFound, scriptError, backgroundFailed]),
                      "a background that failed to load is revived whatever else was recorded")
        XCTAssertFalse(ExtensionDiagnostics.errorsWarrantBackgroundRevive(([backgroundFailed, scriptError] as [any Error]).dropFirst()),
                       "a load failure outside the new errors is not revived again")
    }

    func testDiagnosticDescriptionIncludesDomainCodeMessageAndUserInfo() {
        let error = NSError(
            domain: "WKWebExtensionContextErrorDomain",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "The background content failed to load due to an error."]
        )

        let description = ExtensionDiagnostics.diagnosticDescription(for: error)

        XCTAssertTrue(description.contains("message=\"The background content failed to load due to an error.\""))
        XCTAssertTrue(description.contains("domain=WKWebExtensionContextErrorDomain"))
        XCTAssertTrue(description.contains("code=6"))
        XCTAssertTrue(description.contains("NSLocalizedDescription=The background content failed to load due to an error."))
    }

    @MainActor
    func testSettingsDiagnosticsEntriesIncludeContextErrorsWithoutWakeReason() {
        let entries = SettingsBridgeHandler.extensionDiagnosticsEntries(from: [[
            "id": "example-id",
            "name": "Example Extension",
            "runtimeStatus": "loaded",
            "errorCount": 1,
            "contextErrors": [[
                "index": 0,
                "domain": "WKWebExtensionContextErrorDomain",
                "code": 6,
                "description": "message=\"The background content failed to load due to an error.\" domain=WKWebExtensionContextErrorDomain code=6"
            ]]
        ]], now: { 123 })

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["source"] as? String, "context")
        XCTAssertEqual(entries.first?["extensionId"] as? String, "example-id")
        XCTAssertEqual(entries.first?["level"] as? String, "error")
        XCTAssertEqual(entries.first?["timestamp"] as? TimeInterval, 123)
        XCTAssertTrue((entries.first?["message"] as? String)?.contains("background content failed") == true)
    }

    @MainActor
    func testSettingsDiagnosticsEntriesIncludeExtensionPageErrors() {
        let entries = SettingsBridgeHandler.extensionDiagnosticsEntries(from: [[
            "id": "abcdefghijklmnopabcdefghijklmnop",
            "name": "Example Extension",
            "runtimeStatus": "backgroundLoaded",
            "pageDiagnostics": [[
                "id": "page-error-1",
                "timestamp": 456.0,
                "level": "error",
                "source": "console.error",
                "url": "chrome-extension://example-popup/popup.html",
                "message": "popup crashed"
            ]]
        ]], now: { 123 })

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["source"] as? String, "page")
        XCTAssertEqual(entries.first?["extensionId"] as? String, "abcdefghijklmnopabcdefghijklmnop")
        XCTAssertEqual(entries.first?["extensionName"] as? String, "Example Extension")
        XCTAssertEqual(entries.first?["level"] as? String, "error")
        XCTAssertEqual(entries.first?["timestamp"] as? TimeInterval, 456)
        XCTAssertTrue((entries.first?["message"] as? String)?.contains("popup crashed") == true)
        let metadata = entries.first?["metadata"] as? [String: String]
        XCTAssertEqual(metadata?["pageSource"], "console.error")
    }

    @MainActor
    func testSettingsDiagnosticsEntriesDoNotLabelInfoPageDiagnosticsAsErrors() {
        let entries = SettingsBridgeHandler.extensionDiagnosticsEntries(from: [[
            "id": "abcdefghijklmnopabcdefghijklmnop",
            "name": "Example Extension",
            "runtimeStatus": "backgroundLoaded",
            "pageDiagnostics": [[
                "id": "popup-info",
                "timestamp": 789.0,
                "level": "info",
                "source": "popup.present",
                "message": "Popup popover will present with popupWebView"
            ]]
        ]])

        XCTAssertEqual(entries.first?["level"] as? String, "info")
        XCTAssertEqual(entries.first?["message"] as? String, "Extension page diagnostic: Popup popover will present with popupWebView")
    }
}
