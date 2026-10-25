import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Real Chrome Web Store extensions through Lilo's own install pipeline, plus the in-repo MV3 probe.
/// Needs the network and the live store, so `make swift-test` skips it; `make ext-smoke` runs it.
@MainActor
final class RealExtensionSmokeTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    /// Opens `url` in a tab and returns its text once `isReady` holds, or after `timeout`. A page showing a
    /// form control and no text reads as "[form control]": a search box is no blank popup.
    private func pageText(_ window: MainWindowController, _ url: URL, timeout: TimeInterval, isReady: @escaping (String) -> Bool = { !$0.isEmpty }) async throws -> String {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: url))
        var text = ""
        _ = await pollUntil(timeout: timeout) {
            let engine = window.tabManager.engineTab(for: tab.id)
            // On screen, as a popup: WebKit runs no animation frame for a page no window shows. Unattended,
            // as the agent's tabs: a dialog's sheet would hold the page.
            if let engine {
                self.browserContext.context.agentControl.attach(engine, to: nil)
                engine.agentDialogHandler = { _ in true }
            }
            let page = engine?.view as? WKWebView
            text = (try? await page?.evaluateJavaScript(
                "document.body?.innerText || (document.body?.querySelector('input, button, select, textarea') ? '[form control]' : '')"
            ) as? String) ?? ""
            return isReady(text)
        }
        return text
    }

    private struct TopExtensions: Decodable {
        struct Entry: Decodable {
            let name: String
            let id: String
        }
        let extensions: [Entry]
        /// Picked by hand outside the most used: `make ext-smoke` runs them every time.
        let extra: [Entry]
    }

    /// Extensions of top-extensions.json that do not run cleanly yet, by id, with what breaks them. A
    /// newly broken extension fails the test, and so does a listed one that now runs cleanly.
    static let knownFailures: [String: String] = [
        "fdjamakpfbbddfjaooikfcpapjohcfmg": "Chrome too fails its carbon commands (a is not a function); WebKit reports the ApplicationRequestError its framework rethrows, which Chrome only logs", // Dashlane
        "gjjbmfigjpgnehjioicaalopaikcnheo": "Chrome too: its worker reads settings its backend did not send", // Dark Theme
        "adlpodnneegcnbophopdmhedicjbcgco": "Chrome too: its worker reads settings its backend did not send", // Troywell VPN
        "lieogkinebikhdchceieedcigeafdkid": "Chrome too: its worker fails at startup without the Eagle app (with another error)", // Eagle
        "hfapbcheiepjppjbnkphkmegjlipojba": "Chrome too: its worker reads window, which no service worker has", // Klarna
        "ojplmecpdpgccookcobabopnaifgidhf": "JavaScriptCore checks a binding an assignment across an await targets before the await, so its content scripts' modules throw where V8 waits for the await (WEBKIT-GAPS.md, gap 74)", // Buyhatke
        "agjnjboanicjcpenljmaaigopkgdnihi": "JavaScriptCore rejects `in` in an arrow function body inside a for initializer, so its module worker fails to parse", // PreMiD
        "ckkdlimhmcjmikdlpkmbgfkaikojcbjk": "Chrome too: it removes a required permission (WebKit words the error differently)", // Markdown Viewer
        "oeopbcgkkoapgobdbedcemjljbihmemj": "Lilo has no push backend: it logs the error instanceID.getToken fails with, Chrome's with Instance ID disabled, where Chrome gets a token", // Checker Plus for Gmail
        "inlikjemeeknofckkjolnjbpehgadgge": "WebKit gives extensions no SharedArrayBuffer, so its offscreen document cannot open its SQLite store", // Distill Web Monitor
        "bomfdkbfpdhijjbeoicnfhjbdhncfhig": "WebKit gives extensions no SharedArrayBuffer (WEBKIT-GAPS.md, gap 36): its worker's error reporter logs the ReferenceError", // Paperpile
        "hkhggnncdpfibdhinjiegagmopldibha": "Lilo has no push backend: it logs the error instanceID.getToken fails with, as Checker Plus for Gmail", // Checker Plus for Google Calendar
        "ndakideadaglgpbblmppfonobpdgggin": "Chrome gives it chrome.mdns and chrome.system.network, which Lilo lacks: its worker logs that it cannot look for printers. It finds them to offer through printerProvider, which the macOS print panel never asks", // Mobility Print
        "cmllgdnjnkbapbchnebiedipojhmnjej": "Chrome too: its module worker reads Element, which no worker has, and fails to start (Chrome's reference records the error only)", // Adaware AdBlock
        "doojmbjmlfjjnbmnoijecmcbfeoakpjm": "WebKit runs promise callbacks while importScripts loads (WEBKIT-GAPS.md, gap 14): its tab probe runs before the script declaring ns", // NoScript
        "mkhjobnjhllkhekbbedlkmgcglgaeidc": "Chrome too: its worker finds no Chromebook and disables itself with management.setEnabled, so its popup does not load; Chrome's reference reads the text of its blocked page", // iboss Cloud Connector
        "gkncegdiihdghhkfpnnodppcbjeeimkc": "installed from the store, it needs an enterprise policy's managed configuration; Chrome's reference runs it unpacked (installType development), where it falls back to defaults", // Senso
        "hdjihnnclpjhfdbbinmgoiehhoehhlgf": "its popup waits for the window focus the test's window never gets, then pastes with document.execCommand('paste'), which WebKit answers false: it renders nothing", // Pasty
        "bbejljcbaibhhacdpndojhkhckgdooff": "its popup's first request, which its worker forwards to its offscreen document, comes back with an error without a message, which the popup logs; in Chrome's recording it fails before reaching that document, with 'Could not establish connection'", // Aircall Dialer
        "kagjkiiecagemklhmhkabbalfpbianbe": "WebKit gives its worker browser.extension.getBackgroundPage, which Chrome leaves out of workers and nothing can remove (WEBKIT-GAPS.md, gap 87): its background check compares the result with window and fails to load", // AI Exporter
    ]

    /// Extensions that fail in Lilo only some of the time, by id, with what breaks them: the test reports
    /// them but passes either way, until the cause is fixed and they move out.
    static let intermittent: [String: String] = [
        "cnlhokffphohmfcddnibpohmkdfafdli": "some runs its popup still renders nothing, after other extensions in the same shard; the cause is not yet known", // MultiPassword
        "pphgdbgldlmicfdkhondlafkiomnelnk": "some runs a page connects to its worker before the worker adds its runtime.onConnect listener; it passes on reruns", // 1ClickVPN Proxy for Chrome
        "ocfjjghignicohbjammlhhoeimpfnlhc": "some runs its worker messages a tab before the tab's content script listens; it passes on reruns", // Flash Player Enable
        "bkdgflcldnnnapblkhphbgpggdiikppg": "some runs its worker's privacy-dashboard port hears messages shaped as the answers Lilo sends on its own channel ({reply, result}) and logs them as unrecognized, with the worker running; the cause is not yet known", // DuckDuckGo
        "aicmkgpgakddgnaphhhpliifpcfhicfo": "its worker posts on the port it opens back to its popup, which WebKit disconnects when the popup runs in a tab of another process (WEBKIT-GAPS.md, gap 60)", // Postman Interceptor
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa": "the popup's tab activates while its WebAssembly core starts: its icon update skips a tab with no url, which Chrome reports until the tab commits, where Lilo reports the url from the navigation start (WebKit's own access checks on a loading tab need it)", // 1Password
        "bgnkhhnnamicmpeenaelnjfhikgbkllg": "its worker adds its runtime.onMessage listener and handlers only after an asynchronous setup: its popup, opened as the worker starts, can get no answer (response.listenerId on undefined), a race Chrome runs too and records the same errors for", // AdGuard AdBlocker
        "apjcbfpjihpedihablmalmbbhjpklbdf": "its worker adds its runtime.onMessage listener and handlers only after an asynchronous setup: its popup, opened as the worker starts, can get no answer (response.listenerId on undefined), a race Chrome runs too and records the same errors for", // AdGuard AdBlocker (Beta)
        "gkojfkhlekighikafcpjkiklfbnlmeio": "a tab event can reach its worker before its asynchronous startup has set up what its tab listeners use", // Hola VPN
        "gidejehfgombmkfflghejpncblgfkagj": "its worker's handler fails on a request to its server, which Chrome fails too, before it answers: its content scripts then read the answer as null (e.mode, r.length)", // Cuponomia
        "oiiaigjnkhngdbnoookogelabohpglmd": "some runs fail a request to its API, or WebKit fails to size storage.sync for its set", // HubSpot Sales
        "admmjipmmciaobhojoghlmleefbicajg": "some runs fail Firebase Messaging's support check in its worker; the cause is not yet known", // Norton Password Manager
        "caljgklbbfbcjjanaijlacgncafpegll": "some runs fail Firebase Messaging's support check in its worker, as Norton Password Manager's; the cause is not yet known", // Avira Password Manager
        "kdfieneakcjfaiglcfcgkidlkmlijjnh": "its popup reads its session before the answer to its own request for it (asyncGetSession) comes back, then renders nothing (session[property] on undefined)", // AI Grammar and Spell Checker by Ginger
        "pfjdepjjfjjahkjfpkcgfmfhmnakjfba": "some runs log runtime.lastError 'Could not establish connection' for a message no context receives yet; the cause is not yet known", // Detailed SEO Extension
        "callobklhcbilhphinckomhgkigmfocg": "its worker reads chrome.enterprise.reportingPrivate, which Chrome gives this extension only and Lilo lacks; some runs never reach that read", // Endpoint Verification
        "amfojhdiedpdnlijjbhjnhokbnohfdfb": "its welcome page's content script can ask its worker to check a context menu entry before the worker's storage answer, which creates that entry, has come back", // eJOY AI Dictionary
        "blgcbajigpdfohpgcmbbfnphcgifjopc": "its Flutter build needs Chrome's ImageDecoder and Intl.v8BreakIterator, which WebKit lacks: it asks for a skwasm_heavy build its package does not ship", // ExpressKeys: Password Manager
        "aaengkeeajpfabihmmmnkjpogmfkahjo": "a tab activation after the previous extension's tabs close can show it Lilo's new tab page, which it scripts and Chrome would refuse too; Chrome's recording activates no tab" // TxtAnalyser
    ]

    /// What Chrome does with each of them, recorded by `make chrome-smoke`.
    private struct ChromeSmoke: Decodable {
        struct Recording: Decodable {
            let version: String
            let popupText: Bool?
            let errors: [String]
        }
        let extensions: [String: Recording]
    }

    func testStoreExtensionsInstallStartAndShowTheirPopup() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        // A camera or microphone request is refused as a user would: WebKit asks macOS before Lilo's
        // permission handler, so even a denied request would prompt for the test host. Tab and desktop
        // streams still go through the tab-share shim.
        registry.pageScripts.addUserScript(WKUserScript(source: """
        (() => {
          const shared = navigator.mediaDevices?.getUserMedia?.bind(navigator.mediaDevices);
          if (!shared) return;
          navigator.mediaDevices.getUserMedia = (constraints) =>
            [constraints?.video, constraints?.audio].some((c) => c?.mandatory?.chromeMediaSource)
              ? shared(constraints)
              : Promise.reject(new DOMException('Permission denied', 'NotAllowedError'));
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let top = try JSONDecoder().decode(
            TopExtensions.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("top-extensions.json"))
        )
        let chromeSmoke = try JSONDecoder().decode(
            ChromeSmoke.self,
            from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("chrome-smoke.json"))
        )
        // WebKit and Chrome word the same errors differently; ids and times differ from run to run.
        let normalized = { (message: String) -> String in
            message
                // Chrome's recording keeps the first line of each error.
                .replacingOccurrences(of: #"\n[\s\S]*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"Invalid call to \S+\(\)\. "#, with: "", options: .regularExpression)
                // Lilo reports an unchecked lastError as the Error it raises, where Chrome logs the bare text.
                .replacingOccurrences(of: #"^Error: (?=Unchecked runtime\.lastError: )"#, with: "", options: .regularExpression)
                // A promise rejected with undefined: V8 reports the bare text, JavaScriptCore the value.
                .replacingOccurrences(of: #"^Uncaught \(in promise\)$"#, with: "undefined", options: .regularExpression)
                // A logged "Error: " label stays: of console.error("Error: ", error), WebKit keeps only the label. An unchecked
                // lastError is the same error as the one WebKit reports for a call it fails.
                .replacingOccurrences(
                    of: #"^(Error in event handler: |Error handling response: |Uncaught \(in promise\) |Unchecked runtime\.lastError: )?((Type)?Error: (?! ))?"#,
                    with: "", options: .regularExpression
                )
                .replacingOccurrences(of: "Unexpected keyword '", with: "Unexpected token '")
                // Lilo cannot tell a message nobody answered from one whose listener promised an answer it never sent.
                .replacingOccurrences(
                    of: "A listener indicated an asynchronous response by returning true, but the message channel closed before a response was received",
                    with: "The message port closed before a response was received."
                )
                // V8's and JavaScriptCore's wording of a property read or destructured on undefined or null, of a missing variable and of one declared twice.
                .replacingOccurrences(of: #"Cannot read properties of (undefined|null) \(reading '([^']+)'\)"#, with: "$1.$2", options: .regularExpression)
                .replacingOccurrences(of: #"(undefined|null) is not an object \(evaluating '(?:[^']*\.)?([^'.]+)'\)"#, with: "$1.$2", options: .regularExpression)
                .replacingOccurrences(of: #"Can't find variable: (\S+)"#, with: "$1 is not defined", options: .regularExpression)
                .replacingOccurrences(of: #"Can't create duplicate variable: '([^']+)'"#, with: "Identifier '$1' has already been declared", options: .regularExpression)
                .replacingOccurrences(of: #"Cannot destructure property '([^']+)' (from null or undefined value|of '.*' as it is (undefined|null)\.)"#, with: "Cannot destructure property '$1'", options: .regularExpression)
                // JavaScriptCore quotes the call of something that is not a function.
                .replacingOccurrences(of: #"\. \(In '.*?', '.*?' is [^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #" ?\([^()]*:\d+(:\d+)?\)$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "Load failed", with: "Failed to fetch")
                // A plain object logged or thrown: JavaScriptCore converts it to a string, V8 names its class.
                .replacingOccurrences(of: "[object Object]", with: "Object")
                .replacingOccurrences(of: "No runtime.onConnect listeners found.", with: "Could not establish connection. Receiving end does not exist.")
                .replacingOccurrences(of: #"Cannot find menu item with id \S+"#, with: "Menu item not found.", options: .regularExpression)
                // A worker scripting the active tab at startup meets Chrome's about:blank, Lilo's popup tab
                // or a tab still loading, which WebKit refuses in its own words.
                .replacingOccurrences(of: #"Cannot access contents of (url "[^"]*"|the page)"#, with: "Cannot access contents of url", options: .regularExpression)
                .replacingOccurrences(of: "This extension does not have access to this tab.", with: "Cannot access contents of url")
                .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        }
        // `make ext-smoke` hands each of its parallel runs its share of the list; without it, the top 100.
        let only = ProcessInfo.processInfo.environment["LILO_SMOKE_IDS"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        let selected = only.map { only in (top.extensions + top.extra).filter { only.contains($0.id) } } ?? Array(top.extensions.prefix(100))
        // One JSON line per extension as it ends, so a run that crashes still reports the ones before.
        let report = try ProcessInfo.processInfo.environment["LILO_SMOKE_REPORT"].map { path in
            FileManager.default.createFile(atPath: path, contents: nil)
            return try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        }
        defer { try? report?.close() }
        var results: [String] = []
        for (name, id) in selected.map({ ($0.name, $0.id) }) {
            var problems: [String] = []
            var version = "?"
            var staleChrome: String?
            // The full text of the errors WebKit cuts to their first argument, to debug a failure by.
            var details: [String] = []
            defer {
                results.append(problems.isEmpty ? "ok   \(id) \(name) \(version)" : "FAIL \(id) \(name) \(version): \(problems.joined(separator: "; "))")
                let line: [String: Any?] = [
                    "id": id, "name": name, "version": version, "problems": problems, "details": details, "staleChrome": staleChrome,
                    "known": Self.knownFailures[id], "intermittent": Self.intermittent[id]
                ]
                if let data = try? JSONSerialization.data(withJSONObject: line.compactMapValues { $0 }) {
                    try? report?.write(contentsOf: data + Data("\n".utf8))
                }
            }
            do {
                let package: URL
                do {
                    package = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: id)
                } catch let error as URLError where error.code == .timedOut {
                    // The store's download host times out now and then under the shards' load: once more before failing.
                    package = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: id)
                }
                defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
                try await registry.load(from: package)
            } catch {
                problems.append("install: \(error)")
                if Self.knownFailures[id] == nil && Self.intermittent[id] == nil { XCTFail("\(name) installs: \(error)") }
                continue
            }
            guard let context = registry.context(for: id) else {
                problems.append("does not load")
                if Self.knownFailures[id] == nil && Self.intermittent[id] == nil { XCTFail("\(name) loads") }
                continue
            }
            version = context.webExtension.version ?? "?"
            let recorded = chromeSmoke.extensions[id]
            // Chrome's behavior with another version says nothing about this one: all its errors count.
            let chrome = recorded?.version == version ? recorded : nil
            if chrome == nil { staleChrome = recorded?.version ?? "nothing" }
            if context.webExtension.hasBackgroundContent {
                let loaded = await registry.backgrounds.load(id)
                let connected = await pollUntil(timeout: 10) { registry.lifecycle.worker(of: id) == .running }
                // Chrome's recording opens the popup once the worker's top-level code has run, which its listener report follows.
                _ = await pollUntil(timeout: 2) { registry.gapEvents.reportedListeners(of: id) != nil }
                if !loaded { problems.append("the service worker does not load") }
                if !connected { problems.append("the worker never connects to Lilo") }
                if registry.backgrounds.health(for: id)?.bridgeStatus != "loaded" { problems.append("degraded") }
            }
            if let popup = (context.webExtension.manifest["action"] as? [String: Any])?["default_popup"] as? String, !popup.isEmpty {
                // Resolved as WebKit and Chrome open it: a query or fragment stays one.
                // A popup may wait for its extension's remote configuration first (DuckDuckGo, up to 30 s).
                let text = try await pageText(window, try XCTUnwrap(URL(string: popup, relativeTo: context.baseURL)), timeout: 40)
                if text.isEmpty && chrome?.popupText != false { problems.append("the popup renders nothing") }
            }
            let chromeErrors = (chrome?.errors ?? []).map(normalized)
            // A request for a file the package lacks fails in Chrome too, which reports no extension error for it.
            problems += context.errors
                .filter { ($0 as NSError).domain != WKWebExtension.errorDomain || ($0 as NSError).code != WKWebExtension.Error.resourceNotFound.rawValue }
                .map(\.localizedDescription)
                // WebKit keeps only the leading text of a console.error, so a Chrome error starting with it is the same.
                .filter { error in
                    let error = normalized(error)
                    return error.isEmpty || !chromeErrors.contains { $0.hasPrefix(error) }
                }
                .map { "error: \($0)" }
            if let known = Self.knownFailures[id] {
                XCTAssertFalse(problems.isEmpty, "\(name) now runs cleanly: drop it from knownFailures (\(known))")
            } else if Self.intermittent[id] == nil {
                XCTAssertEqual(problems, [], "\(name)")
            }
            if !problems.isEmpty {
                let diagnostics = registry.backgroundDiagnosticsSnapshots().first { $0["id"] as? String == id }?["pageDiagnostics"] as? [[String: Any]] ?? []
                var seen: Set<String> = []
                details = Array(diagnostics.compactMap { $0["level"] as? String == "error" ? $0["message"] as? String : nil }
                    .map { String($0.prefix(500)) }.filter { seen.insert($0).inserted }.suffix(10))
            }
            await registry.unload(extensionId: id)
            // Each extension starts with no page open, as in a new Chrome profile: WebKit injects content
            // scripts into the pages already open when an extension loads, which Chrome never does.
            for tab in window.tabManager.openTabs { window.closeTabStateFirst(id: tab.id, undoable: false) }
        }
        print("SMOKE summary:\n" + results.joined(separator: "\n"))
    }

    /// A local page for what extensions do past their popup: a sign-in form and a text field. Every
    /// other path answers an image.
    private static let featurePage = """
    <!doctype html><html><head><title>Sign in</title></head><body>
    <h1>Sign in to Example</h1>
    <form action="/login" method="post">
      <label>Email <input type="email" name="email" id="email" autocomplete="username"></label>
      <label>Password <input type="password" name="password" id="password" autocomplete="current-password"></label>
      <button type="submit">Sign in</button>
    </form>
    <textarea id="text" rows="4" cols="60">Ths sentense has sum erors in it.</textarea>
    <p>The quick brown fox jumps over the lazy dog.</p>
    </body></html>
    """

    /// A JSON document, which viewers format, and a playing video, which video tools control.
    private static let jsonDocument = #"{"name":"Example","items":[1,2,3],"nested":{"ok":true,"note":null}}"#
    private static let videoPage = """
    <!doctype html><html><head><title>Video</title></head><body>
    <video id="video" width="640" height="360" autoplay muted playsinline></video>
    <script>
      const canvas = Object.assign(document.createElement('canvas'), { width: 640, height: 360 });
      const context = canvas.getContext('2d');
      setInterval(() => { context.fillStyle = `hsl(${Date.now() / 10 % 360} 60% 50%)`; context.fillRect(0, 0, 640, 360); }, 100);
      document.getElementById('video').srcObject = canvas.captureStream(10);
    </script>
    </body></html>
    """

    /// An extension's part on the feature page (or on `path`), signed out: `check` (page world) holds once
    /// its content scripts did it; `menu` asks for a context menu entry, `command` for a shortcut and what
    /// holds after it. `click` clicks its toolbar button first, and `shows` holds for what that opens outside the page.
    private struct Feature {
        let id: String
        let name: String
        var path = "/"
        let check: String
        var menu = false
        var command: (id: String, check: String)?
        var click = false
        var shows: ((MainWindowController) -> Bool)?
    }

    /// Holds once the ad the page requests again at each evaluation fails: the page may load before
    /// the extension's rules have compiled.
    private static let adBlocked = """
    (() => {
      const last = window.adState, image = new Image();
      image.onload = () => window.adState = 'loaded';
      image.onerror = () => window.adState = 'blocked';
      image.src = '/banner.cgi?ad=' + Math.random();
      return last === 'blocked';
    })()
    """

    private static let features = [
        Feature(id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", name: "Dark Reader", check: "document.querySelectorAll('style.darkreader').length > 0",
                command: ("addSite", "document.querySelectorAll('style.darkreader').length === 0")),
        Feature(id: "kbfnbcaeplbcioakkpcpgfkobkghlhen", name: "Grammarly", check: "document.body.hasAttribute('data-gr-ext-installed')"),
        Feature(id: "iidnbdjijdkbmajdffnidomddglmieko", name: "Quillbot", check: "document.querySelector('[data-qb-installed]') !== null"),
        Feature(id: "hdokiejnpimakedhajhdlcegeplioahd", name: "LastPass", check: "document.querySelector('[data-lastpass-icon-root]') !== null"),
        Feature(id: "fdjamakpfbbddfjaooikfcpapjohcfmg", name: "Dashlane", check: "document.querySelector('[data-dashlane-rid]') !== null"),
        // Its popup sizes itself as a page shown in a tab when it finds a current tab, which collapsed WebKit's popover.
        Feature(id: "ghmbeldphafepmbegfdlkpapadhbakde", name: "Proton Pass", check: "document.querySelector('[data-protonpass-role]') !== null"),
        Feature(id: "ghmbeldphafepmbegfdlkpapadhbakde", name: "Proton Pass popup", check: "true", click: true,
                shows: { window in
                    let context = window.profileContext?.extensions.context(for: "ghmbeldphafepmbegfdlkpapadhbakde")
                    return window.tabManager.openTabs.contains { tab in
                        context?.action(for: window.tabManager.tabAdapter(for: tab.id))?.popupPopover?.contentSize == NSSize(width: 600, height: 430)
                    }
                }),
        Feature(id: "cofdbpoegempjloogbagkncekinflcnj", name: "DeepL", check: "document.querySelector('deepl-input-controller') !== null", menu: true),
        Feature(id: "bpoadfkcbjbfhfodiogcnhhhpibjhbnh", name: "Immersive Translate", check: "document.documentElement.hasAttribute('data-immersive-translate-page-theme')"),
        Feature(id: "gighmmpiobklfepjocnamgkkbiglidom", name: "AdBlock", check: "true", menu: true),
        Feature(id: "cfhdojbkjhnklbpkdaibdccddilifddb", name: "Adblock Plus", check: adBlocked),
        Feature(id: "bfogiafebfohielmmehodmfbbebbbpei", name: "Keeper", check: "document.querySelector('#password[data-keeper-lock-id]') !== null"),
        Feature(id: "jabopobgcpjmedljpbcaablpmlmfcogm", name: "WhatFont", check: "document.getElementById('what-font-ext-container') !== null", click: true),
        Feature(id: "mhjhnkcfbdhnjickkkdbjoemdmbfginb", name: "SelectorGadget", check: "document.getElementById('selectorgadget_main') !== null", click: true),
        Feature(id: "fcoeoabgfenejglbffodgkkbkcdhcgfn", name: "Claude", check: "true", click: true,
                shows: { window in window.sidePanel.webView?.url?.lastPathComponent == "sidepanel.html" }),
        Feature(id: "difoiogjjojoaoomphldepapgpbgkhkb", name: "Sider", check: "true", click: true,
                shows: { window in window.sidePanel.webView?.url?.lastPathComponent == "sidepanel.html" }),
        Feature(id: "ddkjiahejlhfcafbddmgiahcphecmpfh", name: "uBlock Origin Lite", check: adBlocked),
        Feature(id: "bgnkhhnnamicmpeenaelnjfhikgbkllg", name: "AdGuard AdBlocker", check: adBlocked),
        Feature(id: "fmkadmapgofadopljbjfkapdkoienihi", name: "React Developer Tools", check: "typeof window.__REACT_DEVTOOLS_GLOBAL_HOOK__ === 'object'"),
        Feature(id: "nhdogjmejiglipccpnnnanhbledajbpd", name: "Vue.js devtools", check: "typeof window.__VUE_DEVTOOLS_GLOBAL_HOOK__ === 'object'"),
        Feature(id: "lmhkpmbekcpmknklioeibfkpmmfibljd", name: "Redux DevTools", check: "typeof window.__REDUX_DEVTOOLS_EXTENSION__ === 'function'"),
        Feature(id: "bcjindcccaagfpapjjmafapmmgkkhgoa", name: "JSON Formatter", path: "/data.json", check: "document.getElementById('jsonFormatterParsed') !== null"),
        Feature(id: "chklaanhfefbnpoihckbnefhakgolnmc", name: "JSONVue", path: "/data.json", check: "document.querySelector('.collapser, #json') !== null"),
        Feature(id: "nffaoalbilbmmfgbnbgppjihopabppdk", name: "Video Speed Controller", path: "/video", check: "document.querySelector('vsc-controller') !== null"),
        Feature(id: "oldceeleldhonbafppcapldpdifcinji", name: "LanguageTool", check: "document.querySelector('[data-lt-installed], [data-lt-tmp-id]') !== null"),
        Feature(id: "nllcnknpjnininklegdoijpljgdjkijc", name: "Wordtune", check: "window._wordtune_extension_installed === true"),
        Feature(id: "edacconmaakjimmfgnblocblbcdcpbko", name: "Session Buddy", check: "true", click: true,
                shows: { window in window.tabManager.openTabs.contains { $0.url?.host == "edacconmaakjimmfgnblocblbcdcpbko" } }),
        Feature(id: "fdpohaocaechififmbbbbbknoalclacl", name: "GoFullPage", check: "true", click: true,
                shows: { window in window.tabManager.openTabs.contains { $0.url?.lastPathComponent == "capture.html" } })
    ]

    func testStoreExtensionFeaturesWorkOnALocalPage() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        let html = Data(Self.featurePage.utf8), json = Data(Self.jsonDocument.utf8), video = Data(Self.videoPage.utf8)
        let image = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7") ?? Data()
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET / ") { return ("200 OK", ["Content-Type: text/html"], html) }
            if request.hasPrefix("GET /data.json ") { return ("200 OK", ["Content-Type: application/json"], json) }
            if request.hasPrefix("GET /video ") { return ("200 OK", ["Content-Type: text/html"], video) }
            return ("200 OK", ["Content-Type: image/gif"], image)
        }
        // LILO_SMOKE_FEATURES, comma-separated names, runs only those.
        let only = ProcessInfo.processInfo.environment["LILO_SMOKE_FEATURES"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        for feature in Self.features where only?.contains(feature.name) ?? true {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)\(feature.path)"))
            do {
                let package = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: feature.id)
                defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
                try await registry.load(from: package)
            } catch {
                XCTFail("\(feature.name) installs: \(error)")
                continue
            }
            let context = try XCTUnwrap(registry.context(for: feature.id))
            _ = await registry.backgrounds.load(feature.id)
            _ = await pollUntil(timeout: 10) { registry.gapEvents.reportedListeners(of: feature.id) != nil }
            // A welcome page the extension opens on install would take the toolbar button's click: once no tab has
            // opened for 1.5 s, they close.
            if feature.click {
                var quiet = 0, count = window.tabManager.openTabs.count
                for _ in 0..<12 where quiet < 3 {
                    try await Task.sleep(for: .milliseconds(500))
                    quiet = window.tabManager.openTabs.count == count ? quiet + 1 : 0
                    count = window.tabManager.openTabs.count
                }
                for tab in window.tabManager.openTabs { window.closeTabStateFirst(id: tab.id, undoable: false) }
            }
            let tab = try XCTUnwrap(window.createTabStateFirst(url: url))
            let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
            browserContext.context.agentControl.attach(engine, to: nil)
            let page = try XCTUnwrap(engine.view as? WKWebView)
            let holds = { (check: String) in await pollUntil(timeout: 20) { (try? await page.evaluateJavaScript(check)) as? Bool == true } }
            if feature.click {
                window.activateTabStateFirst(id: tab.id)
                // A popover shows only from a window on screen.
                window.window?.orderFront(nil)
                _ = await pollUntil(timeout: 10) { !page.isLoading }
                let button = NSMenuItem()
                button.representedObject = feature.id
                window.openExtensionFromMenu(button)
            }
            if let shows = feature.shows {
                let shown = await pollUntil(timeout: 30) { shows(window) }
                XCTAssertTrue(shown, "\(feature.name) opens what its toolbar button opens")
            }
            let checked = await holds(feature.check)
            XCTAssertTrue(checked, "\(feature.name) does its part on the page")
            if feature.menu, let adapter = window.tabManager.tabAdapter(for: tab.id) {
                let added = await pollUntil(timeout: 10) { !context.menuItems(for: adapter).isEmpty }
                XCTAssertTrue(added, "\(feature.name) adds its context menu entry")
            }
            if let (commandId, after) = feature.command {
                let command = try XCTUnwrap(context.commands.first { $0.id == commandId })
                // A command acts on the active tab, which a welcome page the extension opened on install may be.
                window.activateTabStateFirst(id: tab.id)
                let key = command.activationKey ?? ""
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: command.modifierFlags, timestamp: 0, windowNumber: window.window?.windowNumber ?? 0,
                    context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
                ))
                XCTAssertTrue(registry.handleExtensionKeyDown(event), "\(feature.name)'s \(commandId) shortcut is dispatched")
                let applied = await holds(after)
                XCTAssertTrue(applied, "\(feature.name)'s \(commandId) command acts on the page")
            }
            await registry.unload(extensionId: feature.id)
            for tab in window.tabManager.openTabs { window.closeTabStateFirst(id: tab.id, undoable: false) }
        }
    }

    func testProbeReportsEveryDeclaredNamespaceComplete() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        // Loading rewrites the manifest in place: the probe runs from a copy.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../test-extensions/extension-probe").standardizedFileURL
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("extension-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: source, to: copy)
        try await registry.load(from: copy)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        let loaded = await registry.backgrounds.load(id)
        XCTAssertTrue(loaded)
        // A visited page feeds the probe's history, webNavigation and content-script checks.
        _ = try await pageText(window, try XCTUnwrap(URL(string: "https://example.com/")), timeout: 10)

        let report = try await pageText(window, try XCTUnwrap(context.optionsPageURL), timeout: 30) { $0.contains("NAMESPACES") }
        print("SMOKE probe report:\n\(report)")

        XCTAssertTrue(report.contains("NAMESPACES"), "the probe's report renders")
        // `tabs.discard` and the rest of WebKit's tabs surface; namespaces the probe does not declare read absent.
        for namespace in ["runtime", "storage", "tabs", "tabGroups", "scripting", "declarativeNetRequest", "alarms", "cookies",
                          "contextMenus", "i18n", "permissions", "windows", "action", "commands", "webNavigation", "omnibox",
                          "notifications", "idle", "history", "bookmarks", "downloads", "management"] {
            XCTAssertTrue(report.contains("\(namespace)\tfull"), "\(namespace) is complete in the service worker")
        }
        XCTAssertEqual(context.errors.map(\.localizedDescription), [], "the probe reports no errors")

        // Past the moment WebKit replaces a page's chrome.* objects, Lilo's additions are still there.
        let options = try XCTUnwrap(window.tabManager.engineTab(for: try XCTUnwrap(window.tabManager.activeTabId))?.view as? WKWebView)
        try await Task.sleep(for: .seconds(3))
        let badgeColors = try await options.evaluateJavaScript("typeof chrome.action.getBadgeTextColor + '/' + typeof chrome.runtime.getContexts") as? String
        XCTAssertEqual(badgeColors, "function/function")
        // testMatchOutcome re-evaluates the rules WebKit applies: the probe's static block rule.
        let outcome = try await options.callAsyncJavaScript(
            "return await chrome.declarativeNetRequest.testMatchOutcome({ url: 'https://example.com/lilo-dnr-block-probe', type: 'xmlhttprequest' })",
            arguments: [:], in: nil, contentWorld: .page
        ) as? [String: Any]
        let matched = outcome?["matchedRules"] as? [[String: Any]]
        XCTAssertEqual(matched?.first?["ruleId"] as? Int, 1)
        XCTAssertEqual(matched?.first?["rulesetId"] as? String, "probe_ruleset")
        // A disabled static rule turns inert in its file, which WebKit compiles again; enabled, it is back.
        let disabled = try await options.callAsyncJavaScript("""
            const dnr = chrome.declarativeNetRequest;
            const request = { url: 'https://example.com/lilo-dnr-block-probe', type: 'xmlhttprequest' };
            await dnr.updateStaticRules({ rulesetId: 'probe_ruleset', disableRuleIds: [1] });
            const off = [JSON.stringify(await dnr.getDisabledRuleIds({ rulesetId: 'probe_ruleset' })), (await dnr.testMatchOutcome(request)).matchedRules.length];
            await dnr.updateStaticRules({ rulesetId: 'probe_ruleset', enableRuleIds: [1] });
            const on = [JSON.stringify(await dnr.getDisabledRuleIds({ rulesetId: 'probe_ruleset' })), (await dnr.testMatchOutcome(request)).matchedRules.length];
            return [...off, ...on, JSON.stringify(await dnr.getEnabledRulesets())].join(' ');
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(disabled, #"[1] 0 [] 1 ["probe_ruleset"]"#)
    }
}
