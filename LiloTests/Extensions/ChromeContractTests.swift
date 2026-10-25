import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Lilo must answer the extension-contracts cases as Chrome does (chrome-contracts.json, from `make chrome-contracts`),
/// fill the required properties chrome-types gives each object a case tags (chrome-surface.json), and show a content
/// script, a main-world script and the page the chrome.* and browser.* members Chrome does. A case, a
/// `Type.property (case)` or a `world path` that differs must be listed, with why, in chrome-contract-differences.txt.
@MainActor
final class ChromeContractTests: XCTestCase {
    func testExtensionAPIsBehaveAsInChrome() async throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let recorded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: here.appendingPathComponent("chrome-contracts.json"))) as? [String: Any]
        )
        let chrome = try XCTUnwrap(recorded["results"] as? [String: Any])
        let chromeWorlds = try XCTUnwrap(recorded["contentScript"] as? [String: [String: String]])
        let types = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: here.appendingPathComponent("chrome-surface.json"))) as? [String: Any])?["types"]
                as? [String: [String: Any]]
        )
        let differences = Dictionary(
            try String(contentsOf: here.appendingPathComponent("chrome-contract-differences.txt"), encoding: .utf8)
                .split(separator: "\n").filter { !$0.hasPrefix("#") && $0.contains("|") }
                .map { line -> (String, String) in
                    let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return (parts[0], parts[1])
                },
            uniquingKeysWith: { first, _ in first }
        )

        let server = try await TinyHTTPServer { _ in ("200 OK", ["Content-Type: text/html"], Data("<!doctype html><title>page</title><p>page</p>".utf8)) }
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()

        // Loading rewrites the manifest in place: the probe runs from a copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("extension-contracts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: here.appendingPathComponent("../../test-extensions/extension-contracts").standardizedFileURL, to: copy)
        try await registry.load(from: copy)
        let extensionContext = try XCTUnwrap(registry.loadedExtensions.first.flatMap { registry.context(for: $0.id) })
        var contractURL = try XCTUnwrap(URLComponents(url: extensionContext.baseURL.appendingPathComponent("contract.html"), resolvingAgainstBaseURL: false))
        contractURL.queryItems = [URLQueryItem(name: "site", value: "http://127.0.0.1:\(server.port)")]
        let tab = try XCTUnwrap(window.createTabStateFirst(url: XCTUnwrap(contractURL.url)))
        var page: WKWebView?
        let ready = await pollUntil(timeout: 30) {
            page = window.tabManager.engineTab(for: tab.id)?.view as? WKWebView
            return (try? await page?.evaluateJavaScript("typeof window.runContracts")) as? String == "function"
        }
        XCTAssertTrue(ready, "the contract page loads")
        func run(_ function: String) async throws -> Any {
            let json = try await XCTUnwrap(page).callAsyncJavaScript(
                "return JSON.stringify(await window.\(function)())", arguments: [:], in: nil, contentWorld: .page
            ) as? String
            return try JSONSerialization.jsonObject(with: Data(XCTUnwrap(json).utf8))
        }
        let contracts = try await run("runContracts")
        let lilo = try XCTUnwrap(contracts as? [String: Any])
        let surfaces = try await run("contentSurfaces")
        var liloWorlds = try XCTUnwrap(surfaces as? [String: [String: String]])
        // What the page's own scripts see, in the page world no extension script runs in.
        let surfaceSource = try String(contentsOf: copy.appendingPathComponent("surface.js"), encoding: .utf8)
        let site = try XCTUnwrap(window.createTabStateFirst(url: XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/page"))))
        let pageSurface = await pollUntil(timeout: 10) {
            guard let view = window.tabManager.engineTab(for: site.id)?.view as? WKWebView,
                  (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" else { return false }
            liloWorlds["page"] = try? await view.evaluateJavaScript("\(surfaceSource)\nworldSurface()") as? [String: String]
            return liloWorlds["page"] != nil
        }
        XCTAssertTrue(pageSurface, "the web page loads")

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

        // `Type.property` of each required property an object tagged with its type, or held by one, lacks.
        func missingProperties(_ value: Any?, type: String? = nil) -> Set<String> {
            if let array = value as? [Any] { return array.reduce(into: []) { $0.formUnion(missingProperties($1, type: type)) } }
            guard let object = value as? [String: Any] else { return [] }
            var missing = object.reduce(into: Set<String>()) { $0.formUnion(missingProperties($1.value)) }
            guard let type = type ?? object["@type"] as? String, let required = types[type] else { return missing }
            // `name?` is an optional property holding an object type, checked where present.
            for (key, propertyType) in required {
                let optional = key.hasSuffix("?")
                let property = optional ? String(key.dropLast()) : key
                guard let held = object[property] else {
                    if !optional { missing.insert("\(type).\(property)") }
                    continue
                }
                if let propertyType = propertyType as? String { missing.formUnion(missingProperties(held, type: propertyType)) }
            }
            return missing
        }
        // `Type.property (case)`; a property Chrome leaves out too in that case is optional in practice, whatever chrome-types says.
        let missing = Set(chrome.keys.flatMap { name in
            missingProperties(lilo[name]).subtracting(missingProperties(chrome[name])).map { "\($0) (\(name))" }
        })
        let listedProperties = Set(differences.keys.filter { chrome[$0] == nil && $0.hasSuffix(")") && $0.contains(" (") })
        XCTAssertEqual(missing.subtracting(listedProperties).sorted(), [], "required properties Lilo's objects lack: fill them, or list them with why")
        XCTAssertEqual(listedProperties.subtracting(missing).sorted(), [], "listed missing properties Lilo now fills: drop them")

        // `world path` of each member whose presence or kind differs from Chrome's; a listed path covers its members,
        // and under `chrome` its twin under `browser` too.
        let worldDifferences = Set(chromeWorlds.flatMap { world, chromeSurface in
            let liloSurface = liloWorlds[world] ?? [:]
            return Set(chromeSurface.keys).union(liloSurface.keys).filter { chromeSurface[$0] != liloSurface[$0] }.map { "\(world) \($0)" }
        })
        let listedWorlds = Set(differences.keys.filter { key in chromeWorlds.keys.contains { key.hasPrefix("\($0) ") } })
        func covers(_ listed: String, _ difference: String) -> Bool {
            [listed, listed.replacingOccurrences(of: " chrome.", with: " browser.")].contains { difference == $0 || difference.hasPrefix("\($0).") }
        }
        XCTAssertEqual(
            worldDifferences.filter { difference in !listedWorlds.contains { covers($0, difference) } }.sorted().map { difference -> String in
                let world = String(difference.prefix { $0 != " " })
                let path = String(difference.dropFirst(world.count + 1))
                return "\(difference) chrome: \(chromeWorlds[world]?[path] ?? "missing") lilo: \(liloWorlds[world]?[path] ?? "missing")"
            },
            [],
            "chrome.* or browser.* members a content script or the page sees unlike in Chrome: fix them, or list them with why"
        )
        XCTAssertEqual(
            listedWorlds.filter { listed in !worldDifferences.contains { covers(listed, $0) } }.sorted(),
            [],
            "listed world differences that now match Chrome: drop them"
        )
        XCTAssertEqual(
            Set(differences.keys).subtracting(chrome.keys).subtracting(listedProperties).subtracting(listedWorlds).sorted(),
            [],
            "differences for cases that no longer exist"
        )
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
