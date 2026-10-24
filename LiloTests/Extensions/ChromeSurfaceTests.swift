import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Every chrome.* member a stable Chrome gives an MV3 service worker or extension page on macOS
/// (chrome-surface.json, from `make chrome-surface`) exists in Lilo's, under `chrome` and WebKit's
/// own `browser`, unless chrome-surface-gaps.txt lists it as a known gap that COMPATIBILITY.md describes.
@MainActor
final class ChromeSurfaceTests: XCTestCase {
    private struct Surface: Decodable {
        struct Entry: Decodable {
            let path: String
            let permissions: [String]
            let manifest: [String]
            let worker: Bool
        }
        let surface: [Entry]
    }

    /// Manifest keys the probe declares; members needing another (devtools_page...) live in other contexts.
    private static let probeManifestKeys: Set<String> = ["action", "commands", "omnibox"]

    /// Resolves each path under `browser`, then `chrome`, and returns those missing, prefixed with
    /// their root but for `chrome`; evaluated in the probed context. `browser` goes first as an
    /// extension using only it never reads `chrome`, through which Lilo adds to the namespaces.
    private static func missingScript(_ paths: [String]) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: paths), as: UTF8.self)
        return """
        ['browser', 'chrome'].flatMap((root) => \(json).filter((path) => {
          try {
            // `in` for the last key: runtime.lastError reads undefined without an error, as in Chrome.
            const keys = path.split('.');
            let value = globalThis[root];
            for (const key of keys.slice(0, -1)) value = value?.[key];
            return value == null || !(keys[keys.length - 1] in Object(value));
          } catch {
            return true;
          }
        }).map((path) => root === 'chrome' ? path : `browser.${path}`))
        """
    }

    /// Whether a gap covers `path`; a gap under `chrome` covers the same path under `browser` too.
    private static func covered(_ path: String, by gaps: [String]) -> Bool {
        gaps.contains { gap in path == gap || path.hasPrefix("\(gap).") || path == "browser.\(gap)" || path.hasPrefix("browser.\(gap).") }
    }

    private static func manifest(permissions: [String], background: Bool) -> [String: Any] {
        var manifest: [String: Any] = [
            "manifest_version": 3, "name": "Surface", "version": "1.0",
            "action": [String: Any](), "commands": ["run": ["description": "Run"]], "omnibox": ["keyword": "probe"],
            "permissions": permissions, "host_permissions": ["<all_urls>"]
        ]
        if background { manifest["background"] = ["service_worker": "sw.js"] }
        return manifest
    }

    private func surfaceAndGaps() throws -> (surface: [Surface.Entry], gaps: [String]) {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let surface = try JSONDecoder().decode(Surface.self, from: Data(contentsOf: here.appendingPathComponent("chrome-surface.json")))
        let gaps = try String(contentsOf: here.appendingPathComponent("chrome-surface-gaps.txt"), encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return (surface.surface.filter { Set($0.manifest).isSubset(of: Self.probeManifestKeys) }, gaps)
    }

    func testExtensionPageSurfaceMatchesChrome() async throws {
        let (surface, gaps) = try surfaceAndGaps()
        let expected = surface.filter { !$0.path.hasPrefix("devtools") }
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("surface-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = Self.manifest(permissions: Set(expected.flatMap(\.permissions)).sorted(), background: false)
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "<!doctype html><title>probe</title>".write(to: dir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try await registry.load(from: dir)
        let extensionContext = try XCTUnwrap(registry.loadedExtensions.first.flatMap { registry.context(for: $0.id) })

        let tab = try XCTUnwrap(window.createTabStateFirst(url: extensionContext.baseURL.appendingPathComponent("page.html")))
        var missing: [String]?
        let probed = await pollUntil(timeout: 10) {
            guard let page = window.tabManager.engineTab(for: tab.id)?.view as? WKWebView, page.url?.scheme == "chrome-extension",
                  (try? await page.evaluateJavaScript("typeof chrome?.runtime?.id")) as? String == "string" else { return false }
            missing = try? await page.evaluateJavaScript(Self.missingScript(expected.map(\.path))) as? [String]
            return missing != nil
        }
        XCTAssertTrue(probed, "the extension page loads with chrome.*")
        XCTAssertEqual((missing ?? []).filter { !Self.covered($0, by: gaps) }, [], "missing from Lilo's extension pages: add it, or list it as a gap")
    }

    func testServiceWorkerSurfaceMatchesChrome() async throws {
        let (surface, gaps) = try surfaceAndGaps()
        let expected = surface.filter(\.worker)
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let compatibility = try String(contentsOf: here.appendingPathComponent("../../COMPATIBILITY.md"), encoding: .utf8)

        let manifest = Self.manifest(permissions: Set(expected.flatMap(\.permissions)).sorted(), background: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("surface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "chrome.runtime.sendNativeMessage('lilo.test', { missing: \(Self.missingScript(expected.map(\.path))) });"
            .write(to: dir.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        XCTAssertFalse(ProfileExtensionRegistry.prepareForWebKit(at: dir, allowsUserScripts: true), "prelude preparation degraded")

        let webExtension = try await WKWebExtension(resourceBaseURL: dir)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let receiver = NativeMessageReceiver()
        let reported = expectation(description: "worker reported its surface")
        receiver.received = reported
        controller.delegate = receiver
        let context = WKWebExtensionContext(for: webExtension)
        webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        webExtension.allRequestedMatchPatterns.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)
        try await context.loadBackgroundContent()
        await fulfillment(of: [reported], timeout: 10)
        try controller.unload(context)

        let missing = try XCTUnwrap((receiver.message as? [String: Any])?["missing"] as? [String])
        XCTAssertEqual(missing.filter { !Self.covered($0, by: gaps) }, [], "missing from Lilo's worker: add it, or list it as a gap")
        let expectedGaps = gaps.filter { gap in expected.contains { Self.covered("browser.\($0.path)", by: [gap]) } }
        XCTAssertEqual(expectedGaps.filter { gap in !missing.contains { $0 == gap || $0.hasPrefix("\(gap).") } }, [], "listed as gaps but present: drop them")
        XCTAssertEqual(
            gaps.filter { !compatibility.contains("`\($0)`") && !compatibility.contains("`\($0.split(separator: ".").last!)`") },
            [],
            "gaps COMPATIBILITY.md does not name"
        )
    }
}

