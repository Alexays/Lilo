import WebKit
import XCTest
@testable import Lilo

/// chrome.publicSuffix answers synchronously in a real worker and extension page, from the list the
/// preparer writes into an extension declaring the permission.
@MainActor
final class PublicSuffixTests: XCTestCase {
    private static let probe = "[chrome.publicSuffix.getDomain('www.mail.example.co.uk'), chrome.publicSuffix.isKnownSuffix('github.io')]"

    private func makeExtension(permissions: [String], files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("public-suffix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Suffix", "version": "1.0", "permissions": permissions]
        if files["sw.js"] != nil { manifest["background"] = ["service_worker": "sw.js"] }
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for (name, source) in files {
            try source.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testWorkerAnswersFromItsPrelude() async throws {
        let dir = try makeExtension(permissions: ["publicSuffix", "nativeMessaging"], files: [
            "sw.js": "chrome.runtime.sendNativeMessage('lilo.test', { result: \(Self.probe) });"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(ProfileExtensionRegistry.prepareForWebKit(at: dir, allowsUserScripts: false))

        let webExtension = try await WKWebExtension(resourceBaseURL: dir)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let receiver = NativeMessageReceiver()
        let reported = expectation(description: "worker reported")
        receiver.received = reported
        controller.delegate = receiver
        let context = WKWebExtensionContext(for: webExtension)
        webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)
        try await context.loadBackgroundContent()
        await fulfillment(of: [reported], timeout: 10)
        try controller.unload(context)

        let result = try XCTUnwrap((receiver.message as? [String: Any])?["result"] as? [Any])
        XCTAssertEqual(result.first as? String, "example.co.uk")
        XCTAssertEqual(result.last as? Bool, true)
    }

    func testPageReadsTheListWrittenIntoTheExtension() async throws {
        let dir = try makeExtension(permissions: ["publicSuffix"], files: ["page.html": "<!doctype html><title>probe</title>"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let profileId = try browserContext.context.profileManager.createProfile(name: "P").id
        let registry = try browserContext.context.profileContexts.context(for: profileId).extensions
        try await registry.load(from: dir)
        let context = try XCTUnwrap(registry.loadedExtensions.first.flatMap { registry.context(for: $0.id) })

        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        var result: [Any]?
        let answered = await pollUntil(timeout: 10) {
            guard (try? await page.evaluateJavaScript("typeof chrome?.publicSuffix?.getDomain")) as? String == "function" else { return false }
            result = try? await page.evaluateJavaScript(Self.probe) as? [Any]
            return result != nil
        }
        XCTAssertTrue(answered)
        XCTAssertEqual(result?.first as? String, "example.co.uk")
        XCTAssertEqual(result?.last as? Bool, true)
    }
}
