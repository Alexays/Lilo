import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Lilo must answer the extension-contracts cases as Chrome does (chrome-contracts.json, from `make chrome-contracts`);
/// a case that differs must be listed, with why, in chrome-contract-differences.txt.
@MainActor
final class ChromeContractTests: XCTestCase {
    func testExtensionAPIsBehaveAsInChrome() async throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let recorded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: here.appendingPathComponent("chrome-contracts.json"))) as? [String: Any]
        )
        let chrome = try XCTUnwrap(recorded["results"] as? [String: Any])
        let differences = Dictionary(
            try String(contentsOf: here.appendingPathComponent("chrome-contract-differences.txt"), encoding: .utf8)
                .split(separator: "\n").filter { !$0.hasPrefix("#") && $0.contains("|") }
                .map { line -> (String, String) in
                    let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return (parts[0], parts[1])
                },
            uniquingKeysWith: { first, _ in first }
        )

        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()

        // Loading rewrites the manifest in place: the probe runs from a copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("extension-contracts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: here.appendingPathComponent("../../test-extensions/extension-contracts").standardizedFileURL, to: copy)
        try await registry.load(from: copy)
        let extensionContext = try XCTUnwrap(registry.loadedExtensions.first.flatMap { registry.context(for: $0.id) })
        let tab = try XCTUnwrap(window.createTabStateFirst(url: extensionContext.baseURL.appendingPathComponent("contract.html")))
        var page: WKWebView?
        let ready = await pollUntil(timeout: 30) {
            page = window.tabManager.engineTab(for: tab.id)?.view as? WKWebView
            return (try? await page?.evaluateJavaScript("typeof window.runContracts")) as? String == "function"
        }
        XCTAssertTrue(ready, "the contract page loads")
        let json = try await XCTUnwrap(page).callAsyncJavaScript(
            "return JSON.stringify(await window.runContracts())", arguments: [:], in: nil, contentWorld: .page
        ) as? String
        let lilo = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(json).utf8)) as? [String: Any])

        func canonical(_ value: Any?) -> String {
            guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "missing" }
            return String(decoding: data, as: UTF8.self)
        }
        var unexplained: [String] = []
        var stale: [String] = []
        for name in chrome.keys.sorted() {
            let same = canonical(chrome[name]) == canonical(lilo[name])
            if same, differences[name] != nil { stale.append(name) }
            if !same, differences[name] == nil {
                unexplained.append("\(name)\n  chrome: \(canonical(chrome[name]))\n  lilo:   \(canonical(lilo[name]))")
            }
        }
        XCTAssertEqual(unexplained, [], "cases where Lilo differs from Chrome: fix them, or list them with why")
        XCTAssertEqual(stale, [], "listed differences that now match Chrome: drop them")
        XCTAssertEqual(Set(differences.keys).subtracting(chrome.keys).sorted(), [], "differences for cases that no longer exist")
    }

    /// The store, the CRX download and the update check refuse an extension needing a newer Chrome than
    /// the one Lilo claims, and withhold its updates: the claim keeps up with the Chrome the contracts
    /// are recorded from.
    func testLiloClaimsACurrentChromeVersion() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let recorded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: here.appendingPathComponent("chrome-contracts.json"))) as? [String: Any]
        )
        let recordedMajor = try XCTUnwrap((recorded["chrome"] as? String)?.split(separator: "/").last?.split(separator: ".").first.flatMap { Int($0) })
        let claimedMajor = try XCTUnwrap(ExtensionUpdateChecker.prodVersion.split(separator: ".").first.flatMap { Int($0) })
        XCTAssertGreaterThanOrEqual(claimedMajor, recordedMajor - 2, "update ChromeMasquerade.chromeUserAgent and webstorePrivate.ts")
        let shim = try String(contentsOf: XCTUnwrap(Bundle.appResourceURL("ChromeWebStoreShim", extension: "js")), encoding: .utf8)
        XCTAssertTrue(shim.contains("\"\(claimedMajor)\""), "the store shim claims the same Chrome as the user agent")
    }
}
