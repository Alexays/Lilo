import WebKit
import XCTest
@testable import Lilo

final class ExtensionBackgroundPreparerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testPrepareCreatesClassicWrapperWithoutTouchingVendorScript() throws {
        let extDir = tempDir.appendingPathComponent("classic")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Classic","version":"1","background":{"service_worker":"background.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('vendor');".write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        let result = try ExtensionBackgroundPreparer.prepare(
            extensionURL: extDir,
            preludeSource: "globalThis.__liloBackgroundPreludeInstalled = true;"
        )

        XCTAssertEqual(result, .prepared)
        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("background.js")), "console.log('vendor');")
        let wrapper = try String(contentsOf: extDir.appendingPathComponent("lilo-background-wrapper.js"))
        XCTAssertTrue(wrapper.contains("importScripts('lilo-background-prelude.js');"))
        XCTAssertTrue(wrapper.contains("importScripts(\"background.js\");"))
        let background = try loadBackground(from: extDir)
        XCTAssertEqual(background["service_worker"] as? String, "lilo-background-wrapper.js")
    }

    /// Tampermonkey imports its empty test.js between its startup flag and its listeners.
    func testPreludeListsTheEmptyScriptsAClassicWorkerMayImport() throws {
        let extDir = tempDir.appendingPathComponent("empty-imports")
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Classic","version":"1","background":{"service_worker":"background.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "importScripts('/test.js');".write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try "\n".write(to: extDir.appendingPathComponent("test.js"), atomically: true, encoding: .utf8)
        try "".write(to: extDir.appendingPathComponent("lib/blank.js"), atomically: true, encoding: .utf8)
        try ";".write(to: extDir.appendingPathComponent("lib/semicolon.js"), atomically: true, encoding: .utf8)
        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "P")

        let prelude = try String(contentsOf: extDir.appendingPathComponent("lilo-background-prelude.js"))
        XCTAssertTrue(prelude.contains(#"globalThis.__liloEmptyScripts = ["/lib/blank.js", "/test.js"];"#), prelude)
    }

    /// Wappalyzer and Language Reactor keep `scripts` for Firefox; Chrome runs their service worker.
    func testPrepareRunsTheServiceWorkerOverFirefoxBackgroundScripts() throws {
        let extDir = tempDir.appendingPathComponent("both")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Both","version":"1","background":{"service_worker":"background.js","scripts":["background.js"]}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('vendor');".write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "P"), .prepared)
        XCTAssertEqual(try loadBackground(from: extDir)["preferred_environment"] as? String, "service_worker")
    }

    func testPrepareCreatesModuleWrapper() throws {
        let extDir = tempDir.appendingPathComponent("module")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Module","version":"1","background":{"service_worker":"worker.js","type":"module"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "export {};".write(to: extDir.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)

        _ = try ExtensionBackgroundPreparer.prepare(
            extensionURL: extDir,
            preludeSource: "globalThis.__liloBackgroundPreludeInstalled = true;"
        )

        let wrapper = try String(contentsOf: extDir.appendingPathComponent("lilo-background-wrapper.js"))
        XCTAssertTrue(wrapper.contains("import './lilo-background-prelude.js';"))
        XCTAssertTrue(wrapper.contains("import \"./worker.js\";"))
        let background = try loadBackground(from: extDir)
        XCTAssertEqual(background["type"] as? String, "module")
    }

    /// The wrapper must sit beside a subdirectory worker: the service worker's base URL is the wrapper's, so a root
    /// wrapper would 404 every relative sub-resource load.
    func testPrepareCoLocatesWrapperWithSubdirectoryWorker() throws {
        let extDir = tempDir.appendingPathComponent("subdir-classic")
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("js"), withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Subdir","version":"1","background":{"service_worker":"js/background.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('vendor');".write(to: extDir.appendingPathComponent("js/background.js"), atomically: true, encoding: .utf8)

        let result = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "P")

        XCTAssertEqual(result, .prepared)
        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("js/background.js")), "console.log('vendor');")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extDir.appendingPathComponent("js/lilo-background-prelude.js").path))
        let wrapper = try String(contentsOf: extDir.appendingPathComponent("js/lilo-background-wrapper.js"))
        XCTAssertTrue(wrapper.contains("importScripts('lilo-background-prelude.js');"))
        XCTAssertTrue(wrapper.contains("importScripts(\"background.js\");"), "must import the vendor worker by basename, got: \(wrapper)")
        XCTAssertFalse(wrapper.contains("js/"), "wrapper imports must be co-located basenames, got: \(wrapper)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extDir.appendingPathComponent("lilo-background-wrapper.js").path), "no stray root wrapper")
        let background = try loadBackground(from: extDir)
        XCTAssertEqual(background["service_worker"] as? String, "js/lilo-background-wrapper.js")
        let metadata = try loadMetadata(from: extDir)
        XCTAssertEqual(metadata["originalServiceWorker"] as? String, "js/background.js", "metadata keeps the full root-relative path")
    }

    /// Re-preparing an already-prepared subdirectory extension must be idempotent: the manifest now
    /// points at the co-located wrapper and metadata still names the vendor worker, so recovery
    /// re-prepares into the same subdirectory without wrapping the wrapper or touching the vendor.
    func testPrepareIsIdempotentForSubdirectoryWorker() throws {
        let extDir = tempDir.appendingPathComponent("subdir-idempotent")
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("js"), withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Idem","version":"1","background":{"service_worker":"js/background.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('vendor');".write(to: extDir.appendingPathComponent("js/background.js"), atomically: true, encoding: .utf8)

        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "P")
        let manifestAfterFirst = try String(contentsOf: extDir.appendingPathComponent("manifest.json"))
        let wrapperAfterFirst = try String(contentsOf: extDir.appendingPathComponent("js/lilo-background-wrapper.js"))

        let result = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "P")

        XCTAssertEqual(result, .prepared)
        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("manifest.json")), manifestAfterFirst, "manifest unchanged on re-prepare")
        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("js/lilo-background-wrapper.js")), wrapperAfterFirst, "wrapper unchanged on re-prepare")
        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("js/background.js")), "console.log('vendor');", "vendor worker untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extDir.appendingPathComponent("lilo-background-wrapper.js").path), "no second, root-level wrapper")
    }

    /// Module-type worker in a subdirectory: `import` statements with `./` basenames, co-located.
    func testPrepareCoLocatesModuleWrapperWithSubdirectoryWorker() throws {
        let extDir = tempDir.appendingPathComponent("subdir-module")
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"SubMod","version":"1","background":{"service_worker":"src/worker.js","type":"module"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "export {};".write(to: extDir.appendingPathComponent("src/worker.js"), atomically: true, encoding: .utf8)

        let result = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "P")

        XCTAssertEqual(result, .prepared)
        let wrapper = try String(contentsOf: extDir.appendingPathComponent("src/lilo-background-wrapper.js"))
        XCTAssertTrue(wrapper.contains("import './lilo-background-prelude.js';"))
        XCTAssertTrue(wrapper.contains("import \"./worker.js\";"), "must import the vendor worker by basename, got: \(wrapper)")
        XCTAssertFalse(wrapper.contains("src/"), "wrapper imports must be co-located basenames, got: \(wrapper)")
        let background = try loadBackground(from: extDir)
        XCTAssertEqual(background["service_worker"] as? String, "src/lilo-background-wrapper.js")
        XCTAssertEqual(background["type"] as? String, "module")
        let metadata = try loadMetadata(from: extDir)
        XCTAssertEqual(metadata["originalServiceWorker"] as? String, "src/worker.js")
    }

    /// uBlock Origin Lite's shape: Chrome resolves a root-relative worker path against the extension.
    func testPrepareWrapsARootRelativeModuleWorker() throws {
        let extDir = tempDir.appendingPathComponent("root-relative")
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("js"), withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Root","version":"1","background":{"service_worker":"/js/background.js","type":"module"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "export {};".write(to: extDir.appendingPathComponent("js/background.js"), atomically: true, encoding: .utf8)

        let result = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "P")

        XCTAssertEqual(result, .prepared)
        XCTAssertEqual(try loadBackground(from: extDir)["service_worker"] as? String, "js/lilo-background-wrapper.js")
        XCTAssertEqual(try loadMetadata(from: extDir)["originalServiceWorker"] as? String, "js/background.js")
    }

    func testPrepareRegeneratesPreludeUnconditionallyWhenPreludeChanges() throws {
        let extDir = tempDir.appendingPathComponent("hash")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Hash","version":"1","background":{"service_worker":"background.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('vendor');".write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "one")
        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("lilo-background-prelude.js")), "globalThis.__liloWorkerScript = \"background.js\";\none")
        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "two")

        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("lilo-background-prelude.js")), "globalThis.__liloWorkerScript = \"background.js\";\ntwo")
    }

    /// Metadata carries no `backgroundPreludeHash`, and `readMetadata` round-trips what `prepare` just
    /// wrote (the second `prepare` call below re-reads the metadata written by the first).
    func testMetadataOmitsDeadPreludeHashFieldAndStillRoundTripsThroughReadMetadata() throws {
        let extDir = tempDir.appendingPathComponent("no-hash")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"NoHash","version":"1","background":{"service_worker":"background.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('vendor');".write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "one")
        let metadata = try loadMetadata(from: extDir)
        XCTAssertNil(metadata["backgroundPreludeHash"], "dead field must not be written")
        XCTAssertEqual(metadata["originalServiceWorker"] as? String, "background.js")

        // Re-preparing re-reads the metadata `readMetadata` just parsed above; a successful
        // `.prepared` here proves the field's absence doesn't break parsing.
        let second = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "two")
        XCTAssertEqual(second, .prepared)
        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("lilo-background-prelude.js")), "globalThis.__liloWorkerScript = \"background.js\";\ntwo")
    }

    func testPrepareUsesMetadataWhenManifestAlreadyPointsAtWrapper() throws {
        let extDir = tempDir.appendingPathComponent("already-patched")
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("_lilo"), withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Patched","version":"1","background":{"service_worker":"lilo-background-wrapper.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('vendor');".write(to: extDir.appendingPathComponent("real-bg.js"), atomically: true, encoding: .utf8)
        try #"{"schema":1,"preparedBy":"Lilo","originalServiceWorker":"real-bg.js","originalType":"classic","backgroundPreludeHash":"old"}"#
            .write(to: extDir.appendingPathComponent("_lilo/metadata.json"), atomically: true, encoding: .utf8)

        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "new")

        let wrapper = try String(contentsOf: extDir.appendingPathComponent("lilo-background-wrapper.js"))
        XCTAssertTrue(wrapper.contains("importScripts(\"real-bg.js\");"))
    }

    func testPrepareSkipsUnsafeOriginalServiceWorkerPath() throws {
        let extDir = tempDir.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Unsafe","version":"1","background":{"service_worker":"../outside.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let result = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "prelude")

        XCTAssertEqual(result, .skipped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extDir.appendingPathComponent("_lilo").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extDir.appendingPathComponent("lilo-background-wrapper.js").path))
    }

    /// An unpacked extension edited in place to name a new worker: the manifest wins over old metadata.
    func testPrepareAdoptsAChangedVendorWorkerOverMetadata() throws {
        let extDir = tempDir.appendingPathComponent("changed-worker")
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("_lilo"), withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Changed","version":"2","background":{"service_worker":"./new-bg.js"}}"#
            .write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('new');".write(to: extDir.appendingPathComponent("new-bg.js"), atomically: true, encoding: .utf8)
        try #"{"schema":1,"preparedBy":"Lilo","originalServiceWorker":"old-bg.js","originalType":"classic"}"#
            .write(to: extDir.appendingPathComponent("_lilo/metadata.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "prelude"), .prepared)

        let wrapper = try String(contentsOf: extDir.appendingPathComponent("lilo-background-wrapper.js"))
        XCTAssertTrue(wrapper.contains("importScripts(\"new-bg.js\");"))
        XCTAssertEqual(try loadMetadata(from: extDir)["originalServiceWorker"] as? String, "new-bg.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extDir.appendingPathComponent("lilo-background-prelude.js").path),
                      "a root worker's prelude sits at the root")
    }

    // MARK: - Manifest entries Chrome accepts and WebKit rejects

    @MainActor
    func testAnEmptyExecuteActionCommandStillOpensTheAction() async throws {
        let prepared = try await prepareAsChrome(#"""
        {"action": {"default_title": "Dark"}, "commands": {"_execute_action": {}, "toggle": {"description": "Toggle"}}}
        """#)

        XCTAssertEqual(prepared.errors, [])
        let context = WKWebExtensionContext(for: prepared.webExtension)
        XCTAssertEqual(Set(context.commands.map(\.id)), ["_execute_action", "toggle"])
    }

    @MainActor
    func testAnEmptyContentSecurityPolicyKeepsTheDefaultPolicy() async throws {
        let prepared = try await prepareAsChrome(#"{"content_security_policy": {}}"#)

        XCTAssertEqual(prepared.errors, [])
        XCTAssertNil(prepared.webExtension.manifest["content_security_policy"])
    }

    @MainActor
    func testWebAccessibleResourcesForExtensionIdsAreDropped() async throws {
        let prepared = try await prepareAsChrome(#"""
        {"web_accessible_resources": [
          {"resources": ["page.css"], "matches": ["<all_urls>"]},
          {"resources": ["dev.css"], "matches": ["chrome-extension://ocpdpnakdghopjcifldjidbdmfobmmoi/*"]},
          {"resources": ["shared.css"], "extension_ids": ["ocpdpnakdghopjcifldjidbdmfobmmoi"]},
          {"resources": ["mixed.css"], "matches": ["chrome-extension://ocpdpnakdghopjcifldjidbdmfobmmoi/*", "https://example.com/*"]}
        ]}
        """#)

        XCTAssertEqual(prepared.errors, [])
        let resources = try XCTUnwrap(prepared.webExtension.manifest["web_accessible_resources"] as? [[String: Any]])
        XCTAssertEqual(resources.map { $0["resources"] as? [String] }, [["page.css"], ["dev.css"], ["mixed.css"]])
        XCTAssertEqual(resources.last?["matches"] as? [String], ["chrome-extension://ocpdpnakdghopjcifldjidbdmfobmmoi/*", "https://example.com/*"])
    }

    @MainActor
    func testAMissingDescriptionReadsBlank() async throws {
        let prepared = try await prepareAsChrome("{}")

        XCTAssertEqual(prepared.errors, [])
        XCTAssertEqual(prepared.webExtension.manifest["description"] as? String, " ")
    }

    @MainActor
    func testShortcutKeysAreTrimmedAsChromeTrimsThem() async throws {
        let prepared = try await prepareAsChrome(#"""
        {"action": {}, "commands": {"_execute_action": {"suggested_key": {"default": "Ctrl + Shift + Y", "mac": "Command + Shift + Y"}}}}
        """#)

        XCTAssertEqual(prepared.errors, [])
        let command = try XCTUnwrap(WKWebExtensionContext(for: prepared.webExtension).commands.first { $0.id == "_execute_action" })
        XCTAssertEqual(command.activationKey, "y")
        XCTAssertEqual(command.modifierFlags, [.command, .shift])
    }

    @MainActor
    func testAnEmptyContentScriptListIsDropped() async throws {
        let prepared = try await prepareAsChrome(#"{"content_scripts": []}"#)

        XCTAssertEqual(prepared.errors, [])
        XCTAssertNil(prepared.webExtension.manifest["content_scripts"])
    }

    @MainActor
    func testExternallyConnectableAllURLsAndPortsBecomeWebKitPatterns() async throws {
        let prepared = try await prepareAsChrome(#"""
        {"externally_connectable": {"matches": ["<all_urls>", "https://*.aiprm.com:*/*", "http://local.axepro.com:3000/*", "http://[::2]:8080/*", "http://[::1]/*"]}}
        """#)

        XCTAssertEqual(prepared.errors, [])
        let connectable = try XCTUnwrap(prepared.webExtension.manifest["externally_connectable"] as? [String: Any])
        XCTAssertEqual(connectable["matches"] as? [String], ["*://*/*", "https://*.aiprm.com/*", "http://local.axepro.com/*", "http://[::2]/*", "http://[::1]/*"])
    }

    @MainActor
    func testExternallyConnectableWithNoMatchesNorIdsIsDropped() async throws {
        for entry in [#"{}"#, #"{"ids": []}"#, #"{"matches": [], "ids": []}"#] {
            let prepared = try await prepareAsChrome(#"{"externally_connectable": \#(entry)}"#)

            XCTAssertEqual(prepared.errors, [], entry)
            XCTAssertNil(prepared.webExtension.manifest["externally_connectable"], entry)
        }
    }

    // MARK: - Static declarativeNetRequest rulesets

    /// SBlock and Adblock Ad Blocker Pro: WebKit fails a ruleset past its rule cap and skips a rule it
    /// cannot compile, where Chrome applies them all; once prepared, WebKit applies the others.
    @MainActor
    func testStaticRulesetsApplyOnceRewrittenForWebKit() async throws {
        let extDir = tempDir.appendingPathComponent("rulesets")
        try FileManager.default.createDirectory(at: extDir.appendingPathComponent("rules"), withIntermediateDirectories: true)
        try #"""
        {"manifest_version": 3, "name": "Rules", "version": "1", "description": "Rules",
         "permissions": ["declarativeNetRequest"], "host_permissions": ["<all_urls>"], "action": {"default_title": "waiting"},
         "background": {"service_worker": "background.js"},
         "declarative_net_request": {"rule_resources": [{"id": "big", "enabled": false, "path": "/rules/big.json"}, {"id": "plain", "enabled": false, "path": "plain.json"}]}}
        """#.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        // WebKit expands a rule into one content blocker rule per request domain, and compiles at most 150000.
        let domains = (0...150_000).map { "\"d\($0).example\"" }.joined(separator: ",")
        let big = extDir.appendingPathComponent("rules/big.json")
        try #"""
        [{"id": 1, "action": {"type": "block"}, "condition": {"requestDomains": [\#(domains)]}},
         {"id": 2, "action": {"type": "block"}, "condition": {"regexFilter": "ads\\d+"}},
         {"id": 3, "action": {"type": "block"}, "condition": {"regexFilter": "\\bads\\b"}}]
        """#.write(to: big, atomically: true, encoding: .utf8)
        let plain = #"[{"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "ads"}}]"#
        try plain.write(to: extDir.appendingPathComponent("plain.json"), atomically: true, encoding: .utf8)
        try """
        chrome.declarativeNetRequest.updateEnabledRulesets({ enableRulesetIds: ['big', 'plain'] })
          .then(() => 'applied', (error) => error.message).then((title) => chrome.action.setTitle({ title }));
        """.write(to: extDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "")

        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: big)) as? [[String: Any]])
        XCTAssertEqual(rules.map { ($0["condition"] as? [String: Any])?["regexFilter"] as? String }, ["^lilo-inert-rule:", "ads[0-9]+", "^lilo-inert-rule:"])
        XCTAssertEqual(rules.map { ($0["liloChromeRule"] as? [String: Any])?["id"] as? Int }, [1, 2, 3], "each keeps the extension's own rule")
        XCTAssertEqual(try String(contentsOf: extDir.appendingPathComponent("plain.json"), encoding: .utf8), plain)

        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: extDir))
        context.webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        context.webExtension.allRequestedMatchPatterns.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        try controller.load(context)
        defer { try? controller.unload(context) }
        context.loadBackgroundContent { _ in }
        await pollUntil(timeout: 20) { context.action(for: nil)?.label != "waiting" }
        XCTAssertEqual(context.action(for: nil)?.label, "applied")

        // A ruleset the vendor changes is prepared again.
        try #"[{"id": 1, "action": {"type": "block"}, "condition": {"regexFilter": "ad\\d"}}]"#
            .write(to: extDir.appendingPathComponent("plain.json"), atomically: true, encoding: .utf8)
        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "")
        XCTAssertTrue(try String(contentsOf: extDir.appendingPathComponent("plain.json"), encoding: .utf8).contains(#""regexFilter":"ad[0-9]""#))
    }

    /// AdGuard disables the static rules its user's $badfilter rules cancel.
    func testDisabledStaticRulesTurnInertInTheirFileUntilEnabled() throws {
        let extDir = tempDir.appendingPathComponent("disabled-rules")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Rules", "version": "1",
            "declarative_net_request": ["rule_resources": [["id": "main", "enabled": true, "path": "main.json"]]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: extDir.appendingPathComponent("manifest.json"))
        let ruleset = extDir.appendingPathComponent("main.json")
        try #"[{"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "ads/"}}, {"id": 2, "action": {"type": "block"}, "condition": {"urlFilter": "track"}}]"#
            .write(to: ruleset, atomically: true, encoding: .utf8)
        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "")
        let rulesets = ExtensionBackgroundPreparer.staticRulesets(extensionURL: extDir, manifest: manifest)
        let filters = { () throws -> [String?] in
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ruleset)) as? [[String: Any]])
            return rules.map { ($0["condition"] as? [String: Any]).flatMap { $0["urlFilter"] as? String ?? $0["regexFilter"] as? String } }
        }

        XCTAssertTrue(try ExtensionBackgroundPreparer.updateStaticRules(extensionURL: extDir, rulesets: rulesets, rulesetId: "main", disable: [2, 9], enable: []))
        XCTAssertEqual(try ExtensionBackgroundPreparer.disabledStaticRuleIds(extensionURL: extDir, rulesets: rulesets, rulesetId: "main"), [2, 9])
        XCTAssertEqual(try filters(), ["ads/", "^lilo-inert-rule:"])
        XCTAssertFalse(try ExtensionBackgroundPreparer.updateStaticRules(extensionURL: extDir, rulesets: rulesets, rulesetId: "main", disable: [2], enable: []))
        XCTAssertFalse(try ExtensionBackgroundPreparer.updateStaticRules(extensionURL: extDir, rulesets: rulesets, rulesetId: "main", disable: [], enable: [9]), "no rule has id 9")

        // Prepared again (its stamp gone), the file keeps the rule disabled.
        try FileManager.default.removeItem(at: extDir.appendingPathComponent("_lilo/static-rulesets.txt"))
        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "")
        XCTAssertEqual(try filters(), ["ads/", "^lilo-inert-rule:"])

        XCTAssertTrue(try ExtensionBackgroundPreparer.updateStaticRules(extensionURL: extDir, rulesets: rulesets, rulesetId: "main", disable: [1], enable: [1, 2]), "an id in both lists ends enabled")
        XCTAssertEqual(try ExtensionBackgroundPreparer.disabledStaticRuleIds(extensionURL: extDir, rulesets: rulesets, rulesetId: "main"), [])
        XCTAssertEqual(try filters(), ["ads/", "track"])
        XCTAssertThrowsError(try ExtensionBackgroundPreparer.disabledStaticRuleIds(extensionURL: extDir, rulesets: rulesets, rulesetId: "other")) {
            XCTAssertEqual($0.localizedDescription, "Invalid ruleset id: other.")
        }
    }

    /// Prepares an MV3 manifest made of `entries`, then returns the errors WebKit reports loading it.
    @MainActor
    private func prepareAsChrome(_ entries: String) async throws -> (webExtension: WKWebExtension, errors: [String]) {
        let extDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(entries.utf8)) as? [String: Any])
        manifest.merge(["manifest_version": 3, "name": "Chrome", "version": "1"]) { $1 }
        try JSONSerialization.data(withJSONObject: manifest).write(to: extDir.appendingPathComponent("manifest.json"))

        _ = try ExtensionBackgroundPreparer.prepare(extensionURL: extDir, preludeSource: "")

        let webExtension = try await WKWebExtension(resourceBaseURL: extDir)
        return (webExtension, webExtension.errors.map(\.localizedDescription))
    }

    private func loadBackground(from extDir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: extDir.appendingPathComponent("manifest.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["background"] as? [String: Any])
    }

    private func loadMetadata(from extDir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: extDir.appendingPathComponent("_lilo/metadata.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
