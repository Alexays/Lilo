import WebKit
import XCTest
@testable import Lilo

/// chrome.browsingData, chrome.contentSettings, chrome.fontSettings, chrome.proxy and chrome.instanceID, called through
/// the real gap router as an extension's page or worker reaches them.
@MainActor
final class ExtensionSettingsAPITests: XCTestCase {
    private var tempDir: URL!
    private var factory: WKEngineFactory!
    private var cache: ProfileContextCache!
    private var profile: ProfileContext!
    private var router: GapBridgeRouter!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-api-\(UUID().uuidString)")
        let dbManager = try DatabaseManager(appSupportDirectory: tempDir.path)
        let factory = WKEngineFactory()
        self.factory = factory
        cache = ProfileContextCache { profileId in
            try ProfileContext(profileId: profileId, dbManager: dbManager, gapRouter: factory.gapRouter)
        }
        factory.profileContexts = cache
        let id = TestProfileIds.next()
        cache.pinnedProfileIds = [id]
        profile = try cache.context(for: id)
        router = factory.gapRouter
    }

    override func tearDown() {
        profile?.extensions.controller.configuration.defaultWebsiteDataStore?.proxyConfigurations = []
        router = nil
        profile = nil
        cache = nil
        factory = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func loadExtension(
        permissions: [String] = ["browsingData", "contentSettings", "fontSettings", "proxy", "history"], hostPermissions: [String] = []
    ) async throws -> String {
        let dir = tempDir.appendingPathComponent("ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Settings", "version": "1.0", "permissions": permissions, "host_permissions": hostPermissions
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let before = Set(profile.extensions.loadedExtensions.map(\.id))
        try await profile.extensions.load(from: dir)
        return try XCTUnwrap(profile.extensions.loadedExtensions.map(\.id).first { !before.contains($0) })
    }

    private func call(_ namespace: String, _ method: String, _ params: [String: Any] = [:], from extensionId: String) async -> (result: Any?, error: String?) {
        await router.route(
            namespace: namespace, method: method, params: params,
            extensionId: extensionId, fromWorker: true, registry: profile.extensions
        )
    }

    private func events(_ name: String, to extensionId: String) -> [[String: Any]] {
        profile.extensions.gapEvents.undelivered(to: extensionId)
            .filter { "\($0.namespace).\($0.event)" == name }
            .compactMap { $0.args.first as? [String: Any] }
    }

    // MARK: - proxy

    func testProxySetAppliesTheNormalizedConfigToTheProfileDataStore() async throws {
        let id = try await loadExtension()
        let store = try XCTUnwrap(profile.extensions.controller.configuration.defaultWebsiteDataStore)

        let (_, error) = await call("proxy", "set", ["value": ["mode": "fixed_servers", "rules": ["singleProxy": ["host": "proxy.test"]]]], from: id)
        let (got, _) = await call("proxy", "get", [:], from: id)

        XCTAssertNil(error)
        let details = try XCTUnwrap(got as? [String: Any])
        XCTAssertEqual(details["levelOfControl"] as? String, "controlled_by_this_extension")
        let value = try XCTUnwrap(details["value"] as? NSDictionary)
        XCTAssertEqual(value, ["mode": "fixed_servers", "rules": ["singleProxy": ["scheme": "http", "host": "proxy.test", "port": 80]]] as NSDictionary)
        XCTAssertEqual(store.proxyConfigurations.map { "\($0)" }, ["http_connect Proxy: proxy.test:80"])
        XCTAssertEqual(events("proxy.settings.onChange", to: id).first?["levelOfControl"] as? String, "controlled_by_this_extension")

        _ = await call("proxy", "clear", [:], from: id)
        let (cleared, _) = await call("proxy", "get", [:], from: id)
        XCTAssertEqual((cleared as? [String: Any])?["value"] as? NSDictionary, ["mode": "system"] as NSDictionary)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
    }

    func testProxyRejectsWhatChromeRejects() async throws {
        let id = try await loadExtension()

        let (_, noRules) = await call("proxy", "set", ["value": ["mode": "fixed_servers"]], from: id)
        let (_, both) = await call("proxy", "set", ["value": ["mode": "fixed_servers", "rules": [
            "singleProxy": ["host": "a.test"], "proxyForHttp": ["host": "b.test"]
        ]]], from: id)
        let (_, noPac) = await call("proxy", "set", ["value": ["mode": "pac_script"]], from: id)
        let (_, incognito) = await call("proxy", "get", ["incognito": true], from: id)

        XCTAssertEqual(noRules, "Proxy mode 'fixed_servers' requires a 'rules' field.")
        XCTAssertEqual(both, "Proxy rule for singleProxy and proxyForHttp cannot be set at the same time.")
        XCTAssertEqual(noPac, "Proxy mode 'pac_script' requires a 'pacScript' field with either a 'url' field or a 'data' field.")
        XCTAssertEqual(incognito, "You do not have permission to access incognito preferences.")
    }

    func testTheExtensionLoadedLastControlsTheProxy() async throws {
        let first = try await loadExtension()
        let second = try await loadExtension()

        _ = await call("proxy", "set", ["value": ["mode": "direct"]], from: second)
        let (firstView, _) = await call("proxy", "get", [:], from: first)
        _ = await call("proxy", "set", ["value": ["mode": "fixed_servers", "rules": ["singleProxy": ["host": "a.test"]]]], from: first)
        let (secondView, _) = await call("proxy", "get", [:], from: second)

        XCTAssertEqual((firstView as? [String: Any])?["levelOfControl"] as? String, "controlled_by_other_extensions")
        XCTAssertEqual(((secondView as? [String: Any])?["value"] as? [String: Any])?["mode"] as? String, "direct")
        XCTAssertEqual((secondView as? [String: Any])?["levelOfControl"] as? String, "controlled_by_this_extension")

        // Unloading the controlling extension hands the setting to the next one.
        await profile.extensions.disable(extensionId: second)
        XCTAssertEqual(profile.extensions.controller.configuration.defaultWebsiteDataStore?.proxyConfigurations.count, 1)
    }

    func testProxyErrorFiresForAConnectionFailureWhileAProxyApplies() async throws {
        let id = try await loadExtension()
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        factory.reportProxyFailure(failure, registry: profile.extensions)
        XCTAssertTrue(events("proxy.onProxyError", to: id).isEmpty)

        _ = await call("proxy", "set", ["value": ["mode": "fixed_servers", "rules": ["singleProxy": ["host": "proxy.test", "port": 3128]]]], from: id)
        factory.reportProxyFailure(failure, registry: profile.extensions)

        XCTAssertEqual(events("proxy.onProxyError", to: id) as NSArray, [["fatal": true, "error": "net::ERR_PROXY_CONNECTION_FAILED", "details": ""]] as NSArray)
    }

    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    /// Asks the extensions about a challenge from proxy.test:3128, lets `respond` answer the request `id` heard, and
    /// returns what the tab got: nil for its own prompt.
    private func proxyChallenge(
        heardBy id: String, respond: (String) async -> Void
    ) async throws -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
        let space = URLProtectionSpace(
            proxyHost: "proxy.test", port: 3128, type: NSURLProtectionSpaceHTTPSProxy, realm: "vpn", authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender()
        )
        var answers: [(URLSession.AuthChallengeDisposition, URLCredential?)?] = []
        factory.authenticateProxy(challenge, url: URL(string: "https://example.com/"), tab: nil, registry: profile.extensions) { answers.append($0) }
        if answers.isEmpty, let requestId = events("webRequest.onAuthRequired", to: id).last?["requestId"] as? String {
            await respond(requestId)
        }
        XCTAssertEqual(answers.count, 1)
        return try XCTUnwrap(answers.first)
    }

    /// The worker of `id` reports an onAuthRequired listener, `blocking` or observing only.
    private func reportAuthListener(of id: String, blocking: Bool) {
        profile.extensions.gapEvents.listen(["webRequest.onAuthRequired"] + (blocking ? ["webRequest.onAuthRequired.blocking"] : []), extensionId: id)
    }

    func testProxyChallengeTakesTheCredentialsOfAnAuthProvider() async throws {
        let id = try await loadExtension(permissions: ["proxy", "webRequest", "webRequestAuthProvider"], hostPermissions: ["<all_urls>"])
        reportAuthListener(of: id, blocking: true)
        _ = await call("proxy", "set", ["value": ["mode": "fixed_servers", "rules": ["singleProxy": ["host": "proxy.test", "port": 3128]]]], from: id)

        let answer = try await proxyChallenge(heardBy: id) { requestId in
            _ = await call("webRequest", "answerAuth", ["requestId": requestId, "credentials": ["username": "u", "password": "p"]], from: id)
        }

        let details = try XCTUnwrap(events("webRequest.onAuthRequired", to: id).first)
        XCTAssertEqual(details["isProxy"] as? Bool, true)
        XCTAssertEqual(details["challenger"] as? [String: AnyHashable], ["host": "proxy.test", "port": 3128])
        XCTAssertEqual(details["scheme"] as? String, "basic")
        XCTAssertEqual(details["url"] as? String, "https://example.com/")
        XCTAssertEqual(details["statusCode"] as? Int, 407)
        XCTAssertEqual(answer?.0, .useCredential)
        XCTAssertEqual(answer?.1?.user, "u")
        XCTAssertEqual(answer?.1?.password, "p")
        XCTAssertEqual(profile.extensions.controller.configuration.defaultWebsiteDataStore?.proxyConfigurations.count, 1)
    }

    func testProxyChallengeCancelsOrFallsBackToThePrompt() async throws {
        let id = try await loadExtension(permissions: ["proxy", "webRequest", "webRequestAuthProvider"], hostPermissions: ["<all_urls>"])
        reportAuthListener(of: id, blocking: true)

        let cancelled = try await proxyChallenge(heardBy: id) { requestId in
            _ = await call("webRequest", "answerAuth", ["requestId": requestId, "cancel": true], from: id)
        }
        let unanswered = try await proxyChallenge(heardBy: id) { requestId in
            _ = await call("webRequest", "answerAuth", ["requestId": requestId], from: id)
        }

        XCTAssertEqual(cancelled?.0, .cancelAuthenticationChallenge)
        XCTAssertNil(unanswered)
    }

    func testProxyChallengeGoesToThePromptAtOnceWhenNoListenerMayAnswer() async throws {
        let id = try await loadExtension(permissions: ["proxy", "webRequest", "webRequestAuthProvider"], hostPermissions: ["<all_urls>"])
        reportAuthListener(of: id, blocking: false)

        let answer = try await proxyChallenge(heardBy: id) { _ in XCTFail("the prompt does not wait for an observer") }

        XCTAssertNil(answer)
        XCTAssertEqual(events("webRequest.onAuthRequired", to: id).count, 1, "an observer still hears the challenge")
    }

    func testProxyChallengeSkipsExtensionsWithoutAuthProvider() async throws {
        let id = try await loadExtension(permissions: ["proxy", "webRequest"], hostPermissions: ["<all_urls>"])

        let answer = try await proxyChallenge(heardBy: id) { _ in XCTFail("no extension may answer") }

        XCTAssertNil(answer)
        XCTAssertTrue(events("webRequest.onAuthRequired", to: id).isEmpty)
    }

    // MARK: - fontSettings

    func testFontSettingsReachTheProfilePagesAndAnnounceTheChange() async throws {
        let id = try await loadExtension()
        let tab = factory.createTab(configuration: .init(profileId: profile.profileId))
        let preferences = try XCTUnwrap(tab.view as? WKWebView).configuration.preferences

        let (initial, _) = await call("fontSettings", "getFont", ["genericFamily": "standard"], from: id)
        _ = await call("fontSettings", "setFont", ["genericFamily": "standard", "fontId": "Georgia"], from: id)
        _ = await call("fontSettings", "setDefaultFontSize", ["pixelSize": 20], from: id)
        let (font, _) = await call("fontSettings", "getFont", ["genericFamily": "standard", "script": "Zyyy"], from: id)
        let (size, _) = await call("fontSettings", "getDefaultFontSize", [:], from: id)

        XCTAssertEqual((initial as? [String: Any])?["fontId"] as? String, "Times")
        XCTAssertEqual(font as? NSDictionary, ["fontId": "Georgia", "levelOfControl": "controlled_by_this_extension"] as NSDictionary)
        XCTAssertEqual((size as? [String: Any])?["pixelSize"] as? Int, 20)
        XCTAssertEqual(preferences.value(forKey: "standardFontFamily") as? String, "Georgia")
        XCTAssertEqual(preferences.value(forKey: "defaultFontSize") as? Int, 20)
        XCTAssertEqual(events("fontSettings.onFontChanged", to: id) as NSArray, [[
            "fontId": "Georgia", "genericFamily": "standard", "script": "Zyyy", "levelOfControl": "controlled_by_this_extension"
        ]] as NSArray)

        _ = await call("fontSettings", "clearFont", ["genericFamily": "standard"], from: id)
        XCTAssertEqual(preferences.value(forKey: "standardFontFamily") as? String, "Times")
    }

    func testFontSettingsRejectAnInvalidFontAndListSystemFonts() async throws {
        let id = try await loadExtension()

        let (_, error) = await call("fontSettings", "setFont", ["genericFamily": "serif", "fontId": "Bad;Font"], from: id)
        let (list, _) = await call("fontSettings", "getFontList", [:], from: id)

        XCTAssertEqual(error, "Invalid font ID.")
        let fonts = try XCTUnwrap(list as? [[String: String]])
        XCTAssertTrue(fonts.contains { $0["fontId"] == "Helvetica" })
    }

    func testFontSettingsRejectAnInvalidScriptAndSurviveAMalformedStoredKey() async throws {
        let id = try await loadExtension()
        profile.extensionSettings.set("fontSettings.font.standard.", extensionId: id, to: "Georgia")
        profile.extensionSettings.set("fontSettings.font.bogus.Zyyy", extensionId: id, to: "Georgia")

        let (_, empty) = await call("fontSettings", "setFont", ["genericFamily": "standard", "script": "", "fontId": "Georgia"], from: id)
        let (_, dotted) = await call("fontSettings", "getFont", ["genericFamily": "serif", "script": "La.n"], from: id)
        let (_, error) = await call("fontSettings", "setFont", ["genericFamily": "serif", "script": "Latn", "fontId": "Georgia"], from: id)

        XCTAssertEqual(empty, "Invalid script.")
        XCTAssertEqual(dotted, "Invalid script.")
        XCTAssertNil(error)
        XCTAssertEqual(events("fontSettings.onFontChanged", to: id) as NSArray, [[
            "fontId": "Georgia", "genericFamily": "serif", "script": "Latn", "levelOfControl": "controlled_by_this_extension"
        ]] as NSArray)
    }

    // MARK: - contentSettings

    func testContentSettingsResolveTheMostSpecificRuleThenTheDefault() async throws {
        let id = try await loadExtension()

        _ = await call("contentSettings", "set", ["type": "cookies", "primaryPattern": "https://*.a.test/*", "setting": "block"], from: id)
        _ = await call("contentSettings", "set", ["type": "cookies", "primaryPattern": "https://www.a.test/*", "setting": "session_only"], from: id)
        let (www, _) = await call("contentSettings", "get", ["type": "cookies", "primaryUrl": "https://www.a.test/page"], from: id)
        let (sub, _) = await call("contentSettings", "get", ["type": "cookies", "primaryUrl": "https://img.a.test/"], from: id)
        let (other, _) = await call("contentSettings", "get", ["type": "cookies", "primaryUrl": "http://a.test/"], from: id)
        let (popups, _) = await call("contentSettings", "get", ["type": "popups", "primaryUrl": "https://a.test/"], from: id)

        XCTAssertEqual((www as? [String: Any])?["setting"] as? String, "session_only")
        XCTAssertEqual((sub as? [String: Any])?["setting"] as? String, "block")
        XCTAssertEqual((other as? [String: Any])?["setting"] as? String, "allow")
        XCTAssertEqual((popups as? [String: Any])?["setting"] as? String, "block")

        _ = await call("contentSettings", "clear", ["type": "cookies"], from: id)
        let (cleared, _) = await call("contentSettings", "get", ["type": "cookies", "primaryUrl": "https://www.a.test/"], from: id)
        XCTAssertEqual((cleared as? [String: Any])?["setting"] as? String, "allow")
    }

    func testContentSettingsRejectWhatChromeRejects() async throws {
        let id = try await loadExtension()
        func error(_ params: [String: Any]) async -> String? {
            await call("contentSettings", "set", params, from: id).error
        }

        let path = await error(["type": "images", "primaryPattern": "https://a.test/path", "setting": "block"])
        let scheme = await error(["type": "images", "primaryPattern": "ftp://a.test/*", "setting": "block"])
        let host = await error(["type": "images", "primaryPattern": "https://a.*.test/*", "setting": "block"])
        let cameraDefault = await error(["type": "camera", "primaryPattern": "<all_urls>", "setting": "allow"])
        let embedded = await error(["type": "javascript", "primaryPattern": "https://a.test/*", "secondaryPattern": "https://b.test/*", "setting": "block"])
        let autoVerify = await error(["type": "autoVerify", "primaryPattern": "https://a.test/*", "setting": "block"])
        let (_, url) = await call("contentSettings", "get", ["type": "images", "primaryUrl": "not a url"], from: id)

        XCTAssertEqual(path, "Specific paths are not allowed.")
        XCTAssertEqual(scheme, "Invalid scheme.")
        XCTAssertEqual(host, "Invalid host wildcard.")
        XCTAssertEqual(cameraDefault, "'allow' is not supported as the default setting of camera.")
        XCTAssertEqual(embedded, "Embedded patterns are not supported for this setting.")
        XCTAssertEqual(autoVerify, "Site-specific settings are not allowed for this type. The URL pattern must be '<all_urls>'.")
        XCTAssertEqual(url, "The URL \"not a url\" is invalid.")
    }

    func testAnExtensionRuleOverridesTheUserSitePermission() async throws {
        let id = try await loadExtension()
        factory.contentSettingsHandler.userSetting = { _, type, origin in type == "camera" && origin == "https://a.test" ? "allow" : nil }
        let handler = factory.contentSettingsHandler
        let page = try XCTUnwrap(URL(string: "https://a.test/"))

        let (user, _) = await call("contentSettings", "get", ["type": "camera", "primaryUrl": "https://a.test/"], from: id)
        _ = await call("contentSettings", "set", ["type": "camera", "primaryPattern": "https://a.test/*", "setting": "block"], from: id)
        _ = await call("contentSettings", "set", ["type": "javascript", "primaryPattern": "<all_urls>", "setting": "block"], from: id)
        let (rule, _) = await call("contentSettings", "get", ["type": "camera", "primaryUrl": "https://a.test/"], from: id)

        XCTAssertEqual((user as? [String: Any])?["setting"] as? String, "allow")
        XCTAssertEqual((rule as? [String: Any])?["setting"] as? String, "block")
        XCTAssertEqual(handler.extensionSetting("javascript", primary: page, settings: profile.extensionSettings, registry: profile.extensions, isPrivate: false), "block")

        // Rules last while the extension is installed, and go with it.
        await profile.extensions.unload(extensionId: id)
        XCTAssertNil(handler.extensionSetting("camera", primary: page, settings: profile.extensionSettings, registry: profile.extensions, isPrivate: false))
        XCTAssertNil(profile.extensionSettings.value("contentSettings.camera", extensionId: id))
    }

    // MARK: - browsingData

    func testBrowsingDataRemovesOnlyTheNamedOriginsCookies() async throws {
        let id = try await loadExtension()
        let store = try XCTUnwrap(profile.extensions.controller.configuration.defaultWebsiteDataStore)
        for domain in ["a.test", "b.test"] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "n", .value: "v", .expires: Date(timeIntervalSinceNow: 3600)]))
            await store.httpCookieStore.setCookie(cookie)
        }
        let before = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies]).map(\.displayName)

        let (_, error) = await call("browsingData", "remove", ["options": ["origins": ["https://a.test"]], "dataToRemove": ["cookies": true]], from: id)

        XCTAssertNil(error)
        let after = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies]).map(\.displayName)
        XCTAssertEqual(Set(before), ["a.test", "b.test"])
        XCTAssertEqual(after, ["b.test"])
        await store.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
    }

    func testBrowsingDataSparesWebsitesWhenOriginTypesLeaveThemOut() async throws {
        let id = try await loadExtension()
        let store = try XCTUnwrap(profile.extensions.controller.configuration.defaultWebsiteDataStore)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "a.test", .path: "/", .name: "n", .value: "v", .expires: Date(timeIntervalSinceNow: 3600)]))
        await store.httpCookieStore.setCookie(cookie)

        let (_, error) = await call("browsingData", "remove", ["options": ["originTypes": ["extension": true, "protectedWeb": true]], "dataToRemove": ["cookies": true]], from: id)

        XCTAssertNil(error)
        let after = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies]).map(\.displayName)
        XCTAssertEqual(after, ["a.test"])
        await store.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
    }

    func testBrowsingDataRemovesHistorySinceTheGivenTime() async throws {
        let id = try await loadExtension()
        try profile.history.recordVisit(url: "https://recent.test/", title: "Recent")

        let (_, error) = await call("browsingData", "remove", ["options": ["since": (Date().timeIntervalSince1970 - 60) * 1000], "dataToRemove": ["history": true]], from: id)

        XCTAssertNil(error)
        XCTAssertNil(try profile.history.entry(forURL: "https://recent.test/"))
        XCTAssertEqual(events("history.onVisitRemoved", to: id) as NSArray, [["allHistory": false, "urls": ["https://recent.test/"]]] as NSArray)
    }

    func testBrowsingDataRejectsWhatChromeRejects() async throws {
        let id = try await loadExtension()

        let (_, both) = await call("browsingData", "remove", ["options": ["origins": ["https://a.test"], "excludeOrigins": ["https://b.test"]], "dataToRemove": ["cookies": true]], from: id)
        let (_, history) = await call("browsingData", "remove", ["options": ["origins": ["https://a.test"]], "dataToRemove": ["history": true]], from: id)
        let (_, origin) = await call("browsingData", "remove", ["options": ["excludeOrigins": ["nope"]], "dataToRemove": ["cookies": true]], from: id)

        XCTAssertEqual(both, "Don't set both 'origins' and 'excludeOrigins' at the same time.")
        XCTAssertEqual(history, "At least one data type doesn't support filtering by origin.")
        XCTAssertEqual(origin, "'nope' is not a valid origin.")
    }

    func testEachNamespaceNeedsItsPermission() async throws {
        let id = try await loadExtension(permissions: [])
        for (namespace, method) in [("browsingData", "remove"), ("contentSettings", "get"), ("fontSettings", "getFontList"), ("proxy", "get")] {
            let (_, error) = await call(namespace, method, from: id)
            XCTAssertEqual(error, "Permission '\(namespace)' is required for \(namespace).\(method)")
        }
        let (_, instanceID) = await call("instanceID", "getID", from: id)
        XCTAssertEqual(instanceID, "Permission 'gcm' is required for instanceID.getID")
    }

    // MARK: - instanceID

    func testInstanceIDKeepsItsIDUntilDeletedOrUninstalled() async throws {
        let id = try await loadExtension(permissions: ["gcm"])
        let unset = await call("instanceID", "getCreationTime", from: id)
        XCTAssertEqual(unset.result as? Double, 0, "no creation time before the ID exists")

        let generated = await call("instanceID", "getID", from: id)
        let first = try XCTUnwrap(generated.result as? String)
        XCTAssertNotNil(first.wholeMatch(of: /[c-f][A-Za-z0-9_-]{10}/), "Chrome's format: 8 bytes in base64url, the first 4 bits 0111")
        let again = await call("instanceID", "getID", from: id)
        XCTAssertEqual(again.result as? String, first)
        let creation = await call("instanceID", "getCreationTime", from: id)
        let created = try XCTUnwrap(creation.result as? Double)
        XCTAssertEqual(created, Date().timeIntervalSince1970 * 1000, accuracy: 60_000)

        _ = await call("instanceID", "deleteID", from: id)
        let replaced = await call("instanceID", "getID", from: id)
        XCTAssertNotEqual(try XCTUnwrap(replaced.result as? String), first)

        await profile.extensions.unload(extensionId: id)
        XCTAssertNil(profile.extensionSettings.value("instanceID", extensionId: id), "an uninstall drops the ID")
    }
}
