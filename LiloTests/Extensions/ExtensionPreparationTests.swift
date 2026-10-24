import XCTest
@testable import Lilo

final class ExtensionPreparationTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - __MSG__ resolution

    func testResolvesLocalizedNameFromDefaultLocale() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let locales = dir.appendingPathComponent("_locales/en", isDirectory: true)
        try FileManager.default.createDirectory(at: locales, withIntermediateDirectories: true)
        try #"{"appName":{"message":"Example Extension"}}"#.write(to: locales.appendingPathComponent("messages.json"), atomically: true, encoding: .utf8)

        let resolved = ExtensionInstallReview.resolveLocalizedMessage("__MSG_appName__", defaultLocale: "en", extensionURL: dir)
        XCTAssertEqual(resolved, "Example Extension")
    }

    func testResolvesCaseInsensitiveKey() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let locales = dir.appendingPathComponent("_locales/en", isDirectory: true)
        try FileManager.default.createDirectory(at: locales, withIntermediateDirectories: true)
        try #"{"AppName":{"message":"Example Extension"}}"#.write(to: locales.appendingPathComponent("messages.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ExtensionInstallReview.resolveLocalizedMessage("__MSG_appName__", defaultLocale: "en", extensionURL: dir), "Example Extension")
    }

    func testPassesThroughNonPlaceholderAndMissingLocale() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(ExtensionInstallReview.resolveLocalizedMessage("Plain Name", defaultLocale: "en", extensionURL: dir), "Plain Name")
        XCTAssertEqual(ExtensionInstallReview.resolveLocalizedMessage("__MSG_appName__", defaultLocale: nil, extensionURL: dir), "__MSG_appName__")
        XCTAssertEqual(ExtensionInstallReview.resolveLocalizedMessage("__MSG_missing__", defaultLocale: "en", extensionURL: dir), "__MSG_missing__")
    }

    // MARK: - Content-script compat patching

    private func writeManifest(_ json: String, to dir: URL) throws {
        try json.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }

    /// Fixtures declare no background service worker, so only the content-script compat step applies.
    private func prepareCompat(_ dir: URL, compatSource: String = "/* compat */") throws {
        XCTAssertEqual(
            try ExtensionBackgroundPreparer.prepare(extensionURL: dir, preludeSource: "", compatSource: compatSource),
            .notNeeded
        )
    }

    private func readContentScripts(_ dir: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return manifest["content_scripts"] as? [[String: Any]] ?? []
    }

    func testPrependsCompatToJSContentScripts() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(#"{"content_scripts":[{"js":["vendor.js"],"matches":["<all_urls>"]}]}"#, to: dir)

        try prepareCompat(dir)

        let scripts = try readContentScripts(dir)
        XCTAssertEqual(scripts.first?["js"] as? [String], ["_lilo/lilo-content-compat.js", "vendor.js"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("_lilo/lilo-content-compat.js").path))
    }

    func testContentCompatIsIdempotent() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(#"{"content_scripts":[{"js":["vendor.js"],"matches":["<all_urls>"]}]}"#, to: dir)

        try prepareCompat(dir)
        try prepareCompat(dir)

        let js = try readContentScripts(dir).first?["js"] as? [String]
        XCTAssertEqual(js, ["_lilo/lilo-content-compat.js", "vendor.js"], "compat must appear exactly once")
    }

    func testSkipsCssOnlyContentScripts() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(#"{"content_scripts":[{"css":["styles.css"],"matches":["<all_urls>"]}]}"#, to: dir)

        try prepareCompat(dir)

        let first = try readContentScripts(dir).first
        XCTAssertNil(first?["js"], "css-only entry must not gain a js array")
    }

    /// The compat file refreshes on every call so Lilo updates propagate: content on disk must
    /// always match the latest `compatSource`, even when the manifest entry is already correct.
    func testRefreshesCompatFileOnDiskEvenWhenManifestAlreadyListsIt() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(#"{"content_scripts":[{"js":["_lilo/lilo-content-compat.js","vendor.js"],"matches":["<all_urls>"]}]}"#, to: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("_lilo"), withIntermediateDirectories: true)
        try "/* stale */".write(to: dir.appendingPathComponent("_lilo/lilo-content-compat.js"), atomically: true, encoding: .utf8)

        try prepareCompat(dir, compatSource: "/* fresh */")

        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("_lilo/lilo-content-compat.js")),
            "/* fresh */",
            "compat file must be refreshed even when the manifest already references it"
        )
    }

    func testMainWorldContentScriptsNeverGetTheCompat() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeManifest(#"{"content_scripts":[{"js":["_lilo/lilo-content-compat.js","page.js"],"world":"main","matches":["<all_urls>"]},{"js":["vendor.js"],"matches":["<all_urls>"]}]}"#, to: dir)

        try prepareCompat(dir)

        let scripts = try readContentScripts(dir)
        XCTAssertEqual(scripts[0]["js"] as? [String], ["page.js"], "a MAIN-world entry must lose any compat entry")
        XCTAssertEqual(scripts[1]["js"] as? [String], ["_lilo/lilo-content-compat.js", "vendor.js"])
    }

    func testLeavesAnAlreadyPreparedManifestByteForByte() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = #"{"content_scripts":[{"js":["_lilo/lilo-content-compat.js","vendor.js"],"matches":["<all_urls>"]}],"description":"d"}"#
        try writeManifest(original, to: dir)

        try prepareCompat(dir)

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("manifest.json")), original)
    }
}
