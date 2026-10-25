import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Every chrome.* member a stable Chrome gives an MV3 service worker or extension page on macOS
/// (chrome-surface.json, from `make chrome-surface`) exists in Lilo's, under `chrome` and WebKit's
/// own `browser`, with Chrome's kind (function, event, property) and, for an enum or constant, Chrome's value,
/// unless chrome-surface-gaps.txt lists it as a known gap that COMPATIBILITY.md describes.
@MainActor
final class ChromeSurfaceTests: XCTestCase {
    /// Manifest keys the probe declares; members needing another (devtools_page...) live in other contexts.
    private static let probeManifestKeys: Set<String> = ["action", "commands", "omnibox"]

    /// Resolves each entry's path under `browser`, then `chrome`, in the probed context, and returns
    /// `{ missing, wrong }`: the paths missing, and those of another kind or value than Chrome's, each
    /// prefixed with its root but for `chrome`. `browser` goes first as an extension using only it never
    /// reads `chrome`, through which Lilo adds to the namespaces.
    private static func probeScript(_ entries: [[String: Any]]) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: entries.map { $0.filter { ["path", "kind", "value"].contains($0.key) } }), as: UTF8.self)
        return """
        (() => {
          const canonical = (value) => JSON.stringify(value, (key, item) => item && typeof item === 'object' && !Array.isArray(item)
            ? Object.fromEntries(Object.keys(item).sort().map((name) => [name, item[name]])) : item);
          const missing = [];
          const wrong = [];
          for (const root of ['browser', 'chrome']) {
            for (const { path, kind, value: expected } of \(json)) {
              const name = root === 'chrome' ? path : `browser.${path}`;
              let value;
              try {
                // `in` for the last key: runtime.lastError reads undefined without an error, as in Chrome.
                const keys = path.split('.');
                let parent = globalThis[root];
                for (const key of keys.slice(0, -1)) parent = parent?.[key];
                if (parent == null || !(keys[keys.length - 1] in Object(parent))) { missing.push(name); continue; }
                value = parent[keys[keys.length - 1]];
              } catch {
                missing.push(name);
                continue;
              }
              const found = typeof value?.addListener === 'function' ? 'event' : typeof value;
              const fits = { function: found === 'function', event: found === 'event', namespace: found === 'object' && value !== null,
                enum: found === 'object' && value !== null, property: found !== 'function' }[kind];
              if (!fits) wrong.push(`${name}: ${kind} in Chrome, ${found} in Lilo`);
              else if (expected !== undefined && canonical(value) !== canonical(expected)) wrong.push(`${name}: ${canonical(expected)} in Chrome, ${canonical(value)} in Lilo`);
            }
          }
          return { missing, wrong };
        })()
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

    private func surfaceAndGaps() throws -> (surface: [[String: Any]], gaps: [String]) {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let surface = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: here.appendingPathComponent("chrome-surface.json"))) as? [String: Any])?["surface"]
                as? [[String: Any]]
        )
        let gaps = try String(contentsOf: here.appendingPathComponent("chrome-surface-gaps.txt"), encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return (surface.filter { Set($0["manifest"] as? [String] ?? []).isSubset(of: Self.probeManifestKeys) }, gaps)
    }

    func testExtensionPageSurfaceMatchesChrome() async throws {
        let (surface, gaps) = try surfaceAndGaps()
        let expected = surface.filter { !($0["path"] as? String ?? "").hasPrefix("devtools") }
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("surface-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = Self.manifest(permissions: Set(expected.flatMap { $0["permissions"] as? [String] ?? [] }).sorted(), background: false)
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "<!doctype html><title>probe</title>".write(to: dir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try await registry.load(from: dir)
        let extensionContext = try XCTUnwrap(registry.loadedExtensions.first.flatMap { registry.context(for: $0.id) })

        let tab = try XCTUnwrap(window.createTabStateFirst(url: extensionContext.baseURL.appendingPathComponent("page.html")))
        var probe: [String: [String]]?
        let probed = await pollUntil(timeout: 10) {
            guard let page = window.tabManager.engineTab(for: tab.id)?.view as? WKWebView, page.url?.scheme == "chrome-extension",
                  (try? await page.evaluateJavaScript("typeof chrome?.runtime?.id")) as? String == "string" else { return false }
            probe = try? await page.evaluateJavaScript(Self.probeScript(expected)) as? [String: [String]]
            return probe != nil
        }
        XCTAssertTrue(probed, "the extension page loads with chrome.*")
        XCTAssertEqual((probe?["missing"] ?? []).filter { !Self.covered($0, by: gaps) }, [], "missing from Lilo's extension pages: add it, or list it as a gap")
        XCTAssertEqual(
            (probe?["wrong"] ?? []).filter { line in !Self.covered(String(line.prefix { $0 != ":" }), by: gaps) }, [],
            "of another kind or value in Lilo's extension pages than in Chrome: fix it, or list it as a gap"
        )
    }

    func testServiceWorkerSurfaceMatchesChrome() async throws {
        let (surface, gaps) = try surfaceAndGaps()
        let expected = surface.filter { $0["worker"] as? Bool == true }
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let compatibility = try String(contentsOf: here.appendingPathComponent("../../COMPATIBILITY.md"), encoding: .utf8)

        let manifest = Self.manifest(permissions: Set(expected.flatMap { $0["permissions"] as? [String] ?? [] }).sorted(), background: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("surface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "chrome.runtime.sendNativeMessage('lilo.test', \(Self.probeScript(expected)));"
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

        let probe = try XCTUnwrap(receiver.message as? [String: Any])
        let missing = try XCTUnwrap(probe["missing"] as? [String])
        let wrong = try XCTUnwrap(probe["wrong"] as? [String])
        XCTAssertEqual(missing.filter { !Self.covered($0, by: gaps) }, [], "missing from Lilo's worker: add it, or list it as a gap")
        XCTAssertEqual(
            wrong.filter { line in !Self.covered(String(line.prefix { $0 != ":" }), by: gaps) }, [],
            "of another kind or value in Lilo's worker than in Chrome: fix it, or list it as a gap"
        )
        let expectedGaps = gaps.filter { gap in expected.contains { Self.covered("browser.\($0["path"] as? String ?? "")", by: [gap]) } }
        let differing = missing + wrong.map { line in String(line.prefix { $0 != ":" }) }
        XCTAssertEqual(expectedGaps.filter { gap in !differing.contains { $0 == gap || $0.hasPrefix("\(gap).") } }, [], "listed as gaps but as in Chrome: drop them")
        XCTAssertEqual(
            gaps.filter { !compatibility.contains("`\($0)`") && !compatibility.contains("`\($0.split(separator: ".").last!)`") },
            [],
            "gaps COMPATIBILITY.md does not name"
        )
    }
}
