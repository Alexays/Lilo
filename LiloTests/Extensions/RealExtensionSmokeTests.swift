import AppKit
import Metal
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
        "fdjamakpfbbddfjaooikfcpapjohcfmg": "its device info falls back, while its settings are not yet populated, to a carbon command it does not have (getCommonAppSetting: a is not a function); in Chrome they are by then", // Dashlane
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
        "cmllgdnjnkbapbchnebiedipojhmnjej": "Chrome too: its module worker reads Element, which no worker has, and fails to start (Chrome's reference records the error only)", // Adaware AdBlock
        "doojmbjmlfjjnbmnoijecmcbfeoakpjm": "WebKit runs promise callbacks while importScripts loads (WEBKIT-GAPS.md, gap 14): its tab probe runs before the script declaring ns", // NoScript
        "mkhjobnjhllkhekbbedlkmgcglgaeidc": "Chrome too: its worker finds no Chromebook and disables itself with management.setEnabled, so its popup does not load; Chrome's reference reads the text of its blocked page", // iboss Cloud Connector
        "hdjihnnclpjhfdbbinmgoiehhoehhlgf": "its popup waits for the window focus the test's window never gets, then pastes with document.execCommand('paste'), which WebKit answers false: it renders nothing", // Pasty
        "bbejljcbaibhhacdpndojhkhckgdooff": "its popup's first request, which its worker forwards to its offscreen document, comes back with an error without a message, which the popup logs; in Chrome's recording it fails before reaching that document, with 'Could not establish connection'", // Aircall Dialer
        "kagjkiiecagemklhmhkabbalfpbianbe": "WebKit gives its worker browser.extension.getBackgroundPage, which Chrome leaves out of workers and nothing can remove (WEBKIT-GAPS.md, gap 87): its background check compares the result with window and fails to load", // AI Exporter
        "fgmbnmjmbjenlhbefngfibmjkpbcljaj": "its worker messages the popup's tab while it loads, which Lilo counts as listening (a tab opened on the popup hears tabs.onActivated at once): it gets the closed-port error where Chrome reports no receiver", // Highlight This
        "gighmmpiobklfepjocnamgkkbiglidom": "two of its content script entries for its welcome page list adblock-functions.js: WebKit runs it twice in one world, and the second run fails to redeclare determineUserLanguage, which Chrome does not report", // AdBlock
        "cfhdojbkjhnklbpkdaibdccddilifddb": "its options page reads its worker's answers as undefined (addonLocale.locale, features.devToolsPanel, its subscriptions), where Chrome's renders without an error", // Adblock Plus
        "ecnphlgnajanjnkcmbpancdjoidceilk": "its options page renders nothing in 20 s, where Chrome's shows its settings", // Kami
        "ihcjicgdanjaechkgeegckofjjedodee": "its cosmetic filters hide none of the test page's ads, which Chrome's hide; once its worker was idle, its popup over a blank tab shows less than half of Chrome's", // Malwarebytes Browser Guard
        "fdpohaocaechififmbbbbbknoalclacl": "its welcome page finds no window holding it ('No matching window found'), where Chrome's does", // GoFullPage
        "ekhagklcjbdpajgpjgmbionohlpdbjgc": "on the test page its content script fails to initialize translation: its worker creates its offscreen document twice ('Only a single offscreen document may be created')", // Zotero Connector
        "flliilndjeohchalpbbcdekjklbdgfkk": "a message of its worker reaches no listener ('Could not establish connection'), which Chrome's recording does not log", // Avira Browser Safety
        "eppiocemhmnlbhjplcgkofciiegomcon": "its popup's error reporter (bugsnag) logs a failed request, which Chrome's does not", // Urban VPN Proxy
        "pejdijmoenmkgeppbflobdenhhabjlaj": "a message of its worker reaches no listener ('Could not establish connection'), which Chrome's recording does not log", // iCloud Passwords
        "hdhinadidafjejdhmfkjgnolgimiaplp": "over a blank tab its popup shows WebKit's wording of the scripting.executeScript error, where Chrome's shows 'Cannot access contents of the page'", // Read Aloud
        "mmioliijnhnoblpgimnlajmefafdfilb": "the stream its tab capture gets is no MediaStream to AudioContext.createMediaStreamSource, so it cannot listen", // Shazam
        "gomekmidlodglbbmalcneegieacbdmki": "its popup logs an object as an error ([object Object]), which Chrome's does not", // Avast Online Security & Privacy
        "jabjbhgjaidecageckilhonbggakppme": "once its worker was idle, its popup reads its configuration as undefined (result.config.map)", // Gosplagin
        "mpnlkmlkncncpgnnkmkgoobfpnjmblnk": "on the test page its content script reads its testing state as undefined (e.isInitialized)", // Norton Safe Search
        "hkgfoiooedgoejojocmhlaklaeopbecg": "WebKit's MediaSession has no enterpictureinpicture action, which its content script sets on every page (autoPip.js)", // Picture-in-Picture Extension
        "jjkchpdmjjdmalgembblgafllbpcjlei": "its worker reads supportedFeatures.features of an answer that is undefined", // Trellix Endpoint Security Web Control
        "lgblnfidahcdcjddiepkckcfdhpknnjh": "its cosmetic filters hide none of the test page's ads, which Chrome's hide", // Stands AdBlocker
        "mclkkofklkfljcocdinagocijmpgbhab": "over a blank tab its popup calls tabs.detectLanguage, which WebKit refuses for want of access", // Google Input Tools
        "mcbpblocgmgfnpjjppndjkmgjaogfceg": "over a blank tab its popup offers to capture it, where Chrome's recording opens the popup in a tab of its own, which it says it cannot capture", // FireShot
        "dgjbaljgolmlcmmklmmeafecikidmjpi": "its first start registers its cosmetic filters in basic mode: the optimal mode it sets meanwhile meets its own registration still running, which WebKit's slower resource loads while it compiles 50 rulesets keep longer than Chrome's; its next start registers them", // Adblock Ad Blocker Pro
    ]

    /// Extensions that fail in Lilo only some of the time, by id, with what breaks them: the test reports
    /// them but passes either way, until the cause is fixed and they move out.
    static let intermittent: [String: String] = [
        "nngceckbapebfimnlniiiahkandclblb": "some runs its badge update meets a tab the smoke closed meanwhile (No tab with id)", // Bitwarden
        "npnbdojkgkbcdfdjlfdmplppdphlhhcf": "on GitHub's macOS runners its popup and page widgets stay empty, where its worker's getImageData fails; it passes on a Mac", // ProWritingAid
        "cdjkkeofanojcdolaakkckkmfcjejlij": "WebKit runs promise callbacks while importScripts loads (WEBKIT-GAPS.md, gap 14): some runs its status thread starts before the script defining WEBSOCKET_CONNECTED", // GIS NR plugin
        "gejiddohjgogedgjnonbofjigllpkmbf": "as 1Password's: the popup's tab activates while its WebAssembly core starts, so its context menu update fails", // 1Password Nightly
        "ofpnmcalabcbjgholdjcjblkibolbppb": "some runs its worker removes and recreates its quick-action menu from concurrent events, racing itself", // Monica
        "ienfalfjdbdpebioblfackkekamfmbnh": "some runs a content script connects while its worker is not running yet; the cause is not yet known", // Angular DevTools
        "gkncegdiihdghhkfpnnodppcbjeeimkc": "some runs pass: installed from the store, it needs an enterprise policy's managed configuration; Chrome's reference runs it unpacked (installType development), where it falls back to defaults", // Senso
        "pphgdbgldlmicfdkhondlafkiomnelnk": "some runs a page connects to its worker before the worker adds its runtime.onConnect listener; it passes on reruns", // 1ClickVPN Proxy for Chrome
        "ocfjjghignicohbjammlhhoeimpfnlhc": "some runs its worker messages a tab before the tab's content script listens; it passes on reruns", // Flash Player Enable
        "bkdgflcldnnnapblkhphbgpggdiikppg": "some runs its worker's privacy-dashboard port hears messages shaped as the answers Lilo sends on its own channel ({reply, result}) and logs them as unrecognized, with the worker running; the cause is not yet known", // DuckDuckGo
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa": "the popup's tab activates while its WebAssembly core starts: its icon update skips a tab with no url, which Chrome reports until the tab commits, where Lilo reports the url from the navigation start (WebKit's own access checks on a loading tab need it)", // 1Password
        "bgnkhhnnamicmpeenaelnjfhikgbkllg": "its worker adds its runtime.onMessage listener and handlers only after an asynchronous setup: its popup, opened as the worker starts, can get no answer (response.listenerId on undefined), a race Chrome runs too and records the same errors for", // AdGuard AdBlocker
        "apjcbfpjihpedihablmalmbbhjpklbdf": "its worker adds its runtime.onMessage listener and handlers only after an asynchronous setup: its popup, opened as the worker starts, can get no answer (response.listenerId on undefined), a race Chrome runs too and records the same errors for", // AdGuard AdBlocker (Beta)
        "gkojfkhlekighikafcpjkiklfbnlmeio": "a tab event can reach its worker before its asynchronous startup has set up what its tab listeners use", // Hola VPN
        "gidejehfgombmkfflghejpncblgfkagj": "its worker's handler fails on a request to its server, which Chrome fails too, before it answers: its content scripts then read the answer as null (e.mode, r.length)", // Cuponomia
        "oiiaigjnkhngdbnoookogelabohpglmd": "some runs fail a request to its API, or WebKit fails to size storage.sync for its set", // HubSpot Sales
        "admmjipmmciaobhojoghlmleefbicajg": "WebKit gives its worker no PushManager or PushSubscription, so Firebase Messaging's support check fails once its IndexedDB check answers, some 20 to 40 ms after its top-level code: the error is reported only when it lands before the test reads the errors", // Norton Password Manager
        "caljgklbbfbcjjanaijlacgncafpegll": "WebKit gives its worker no PushManager or PushSubscription, so Firebase Messaging's support check fails, as Norton Password Manager's, and is reported only when it lands before the test reads the errors", // Avira Password Manager
        "kdfieneakcjfaiglcfcgkidlkmlijjnh": "its popup reads its session before the answer to its own request for it (asyncGetSession) comes back, then renders nothing (session[property] on undefined)", // AI Grammar and Spell Checker by Ginger
        "pfjdepjjfjjahkjfpkcgfmfhmnakjfba": "some runs log runtime.lastError 'Could not establish connection' for a message no context receives yet; the cause is not yet known", // Detailed SEO Extension
        "callobklhcbilhphinckomhgkigmfocg": "its worker reads chrome.enterprise.reportingPrivate, which Chrome gives this extension only and Lilo lacks; some runs never reach that read", // Endpoint Verification
        "amfojhdiedpdnlijjbhjnhokbnohfdfb": "its welcome page's content script can ask its worker to check a context menu entry before the worker's storage answer, which creates that entry, has come back", // eJOY AI Dictionary
        "blgcbajigpdfohpgcmbbfnphcgifjopc": "its Flutter build needs Chrome's ImageDecoder and Intl.v8BreakIterator, which WebKit lacks: it asks for a skwasm_heavy build its package does not ship", // ExpressKeys: Password Manager
        "aaengkeeajpfabihmmmnkjpogmfkahjo": "a tab activation after the previous extension's tabs close can show it Lilo's new tab page, which it scripts and Chrome would refuse too; Chrome's recording activates no tab", // TxtAnalyser
        "dcngeagmmhegagicpcmpinaoklddcgon": "in a full shard its popup shows no text in 40 s, alone it renders in 2 s; the cause is not yet known", // Web PKI
        "hdokiejnpimakedhajhdlcegeplioahd": "some runs a call of its content script to Lilo is cut as the test page closes, which it logs ('Lilo is unreachable')", // LastPass
        "bhlhnicpbhignbdhedgjhgdocnmhomnp": "some runs it scripts or messages a tab the test just closed (Tab not found); over a blank tab, WebKit refuses its tabs.captureVisibleTab", // ColorZilla
        "cofdbpoegempjloogbagkncekinflcnj": "some runs it messages a tab the test just closed (Tab not found)", // DeepL
        "cdonnmffkdaoajfknoeeecmchibpmkmg": "some runs it sets the icon and title of a tab the test just closed (No tab with id)", // Saladict
    ]

    /// `page`'s answer to `script`, or nil after 5 s: a page whose process hangs never answers, and the run would stop there.
    private func evaluate(_ script: String, in page: WKWebView?) async -> Any? {
        guard let page else { return nil }
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { continuation in
            let finish = { (value: Any?) in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            page.evaluateJavaScript(script) { result, _ in finish(result) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                finish(nil)
            }
        }
    }

    /// Opens `url` in a tab and reads its fingerprint (smoke-probes.js) every 250 ms, as Chrome's recording does, until it
    /// shows at least half of `expected`, Chrome's, or anything without one, for at most `timeout`; then closes the tab.
    /// Returns the last fingerprint and whether it matched.
    /// `closed` when the page closed its own tab, as a popup does that finds itself in one (NordPass, Zoom to Fill).
    /// The page stays open as long as Chrome's recording keeps it: 5 s at least, then until its fingerprint held 2 s, so
    /// what the extension still exchanges as it settles ends as in Chrome. `matchedAfter` is when it first matched.
    private func render(_ window: MainWindowController, _ url: URL, probes: String, like expected: Set<String>, timeout: TimeInterval) async throws -> (tokens: Set<String>, matched: Bool, closed: Bool, matchedAfter: TimeInterval?) {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: url))
        defer { window.closeTabStateFirst(id: tab.id, undoable: false) }
        let opened = Date()
        var tokens: Set<String> = [], matchedAfter: TimeInterval?, still = opened
        let matches = { (tokens: Set<String>) in expected.isEmpty ? !tokens.isEmpty : expected.intersection(tokens).count * 2 >= expected.count }
        while Date().timeIntervalSince(opened) < timeout {
            try await Task.sleep(for: .milliseconds(250))
            if !window.tabManager.openTabs.contains(where: { $0.id == tab.id }) { return (tokens, false, true, nil) }
            guard let engine = window.tabManager.engineTab(for: tab.id) else { continue }
            // As pageText: on screen, as a popup, and unattended.
            browserContext.context.agentControl.attach(engine, to: nil)
            engine.agentDialogHandler = { _ in true }
            let page = engine.view as? WKWebView
            let sampled = Set(await evaluate("(\(probes)).fingerprint()", in: page) as? [String] ?? [])
            if sampled != tokens { still = Date() }
            tokens = sampled
            if matchedAfter == nil, matches(tokens) { matchedAfter = Date().timeIntervalSince(opened) }
            if matchedAfter != nil, Date().timeIntervalSince(opened) >= 5, Date().timeIntervalSince(still) >= 2 { break }
        }
        return (tokens, matchedAfter != nil, false, matchedAfter)
    }

    /// What Chrome does with each of them, recorded by `make chrome-smoke`.
    private struct ChromeSmoke: Decodable {
        /// A page's fingerprint (smoke-probes.js), space-separated, and the milliseconds until it showed most of it.
        struct Render: Decodable {
            let tokens: String
            let ms: Int?
        }
        struct Recording: Decodable {
            let version: String
            let popupText: Bool?
            let popup: Render?
            /// The popup opened again once the worker was stopped.
            let restartPopup: Render?
            let options: Render?
            /// What its content scripts changed on smoke-page.html (smoke-probes.js).
            let page: [String]?
            /// The contexts of each context menu item it adds that applies on that page.
            let menus: [String]?
            /// From the popup's opening on a stopped worker to the worker's top-level code having run.
            let workerRestartMs: Int?
            let errors: [String]
        }
        let extensions: [String: Recording]
    }

    /// One extension's results, written to the report once its last check, maybe the idle one, is done.
    private final class Outcome {
        let id: String, name: String
        var version = "?"
        var staleChrome: String?
        var problems: [String] = []
        /// The full text of the errors WebKit cuts to their first argument, to debug a failure by.
        var details: [String] = []
        /// Milliseconds each step took, and the steps reported as slow.
        var timings: [String: Int] = [:]
        var slow: [String] = []
        /// The worker's state when the idle check clicked the toolbar button.
        var idle: String?

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        /// Reported, never failed: past 5 s, or past 3 times Chrome's time and a second more.
        func time(_ step: String, since start: Date, chrome: Int?) {
            time(step, ms: Int(Date().timeIntervalSince(start) * 1000), chrome: chrome)
        }

        func time(_ step: String, ms: Int, chrome: Int?) {
            timings[step] = ms
            if ms > 5000 || chrome.map({ ms > 3 * $0 && ms - $0 > 1000 }) == true {
                slow.append("\(step) \(ms) ms" + (chrome.map { " (Chrome \($0) ms)" } ?? ""))
            }
        }
    }

    func testStoreExtensionsInstallStartAndShowTheirPopup() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        // The idle check's profile: there, nothing but the check wakes the workers. Its window stays on screen, as a
        // popover shows only from one, with a blank tab for the toolbar button to act on.
        let (idleWindow, idleRegistry) = try browserContext.makeExtensionWindow()
        idleWindow.window?.orderFront(nil)
        let blank = try XCTUnwrap(idleWindow.createTabStateFirst(url: try XCTUnwrap(URL(string: "about:blank"))))
        idleWindow.activateTabStateFirst(id: blank.id)
        // A camera or microphone request is refused as a user would: WebKit asks macOS before Lilo's
        // permission handler, so even a denied request would prompt for the test host. Tab and desktop
        // streams still go through the tab-share shim.
        for registry in [registry, idleRegistry] {
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
        }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let top = try JSONDecoder().decode(TopExtensions.self, from: Data(contentsOf: folder.appendingPathComponent("top-extensions.json")))
        let chromeSmoke = try JSONDecoder().decode(ChromeSmoke.self, from: Data(contentsOf: folder.appendingPathComponent("chrome-smoke.json")))
        // The same probes and test page as Chrome's recording.
        let probes = try String(contentsOf: folder.appendingPathComponent("smoke-probes.js"), encoding: .utf8)
        let smokePage = try String(contentsOf: folder.appendingPathComponent("smoke-page.html"), encoding: .utf8)
        // As a JavaScript string literal.
        let originalPage = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: smokePage, options: .fragmentsAllowed), encoding: .utf8))
        let html = Data(smokePage.utf8), image = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7") ?? Data()
        let server = try await TinyHTTPServer { request in
            request.hasPrefix("GET / ") ? ("200 OK", ["Content-Type: text/html"], html) : ("200 OK", ["Content-Type: image/gif"], image)
        }
        let pageURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
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
                .replacingOccurrences(of: #"Cannot (?:read|set) properties of (undefined|null) \((?:reading|setting) '([^']+)'\)"#, with: "$1.$2", options: .regularExpression)
                .replacingOccurrences(of: #"(undefined|null) is not an object \(evaluating '(?:.*\.)?([\w$]+) = .*'\)"#, with: "$1.$2", options: .regularExpression)
                .replacingOccurrences(of: #"(undefined|null) is not an object \(evaluating '(?:[^']*\.)?([^'.]+)'\)"#, with: "$1.$2", options: .regularExpression)
                .replacingOccurrences(of: #"Can't find variable: (\S+)"#, with: "$1 is not defined", options: .regularExpression)
                .replacingOccurrences(of: #"Can't create duplicate variable: '([^']+)'"#, with: "Identifier '$1' has already been declared", options: .regularExpression)
                .replacingOccurrences(of: #"Cannot destructure property '([^']+)' (from null or undefined value|of '.*' as it is (undefined|null)\.)"#, with: "Cannot destructure property '$1'", options: .regularExpression)
                // JavaScriptCore quotes the call of something that is not a function.
                .replacingOccurrences(of: #"\. \(In '.*?', '.*?' is [^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #" ?\([^()]*:\d+(:\d+)?\)$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^".*" cannot be parsed as a URL\.$"#, with: "Failed to construct 'URL': Invalid URL", options: .regularExpression)
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
        let finish = { (outcome: Outcome) in
            let (id, name, problems) = (outcome.id, outcome.name, outcome.problems)
            results.append(problems.isEmpty ? "ok   \(id) \(name) \(outcome.version)" : "FAIL \(id) \(name) \(outcome.version): \(problems.joined(separator: "; "))")
            let line: [String: Any?] = [
                "id": id, "name": name, "version": outcome.version, "problems": problems, "details": outcome.details,
                "staleChrome": outcome.staleChrome, "known": Self.knownFailures[id], "intermittent": Self.intermittent[id],
                "timings": outcome.timings, "slow": outcome.slow, "idle": outcome.idle
            ]
            if let data = try? JSONSerialization.data(withJSONObject: line.compactMapValues { $0 }) {
                try? report?.write(contentsOf: data + Data("\n".utf8))
            }
            if let known = Self.knownFailures[id] {
                XCTAssertFalse(problems.isEmpty, "\(name) now runs cleanly: drop it from knownFailures (\(known))")
            } else if Self.intermittent[id] == nil {
                XCTAssertEqual(problems, [], "\(name)")
            }
        }
        let errorsOf = { (registry: ProfileExtensionRegistry, id: String) -> [String] in
            let diagnostics = registry.backgroundDiagnosticsSnapshots().first { $0["id"] as? String == id }?["pageDiagnostics"] as? [[String: Any]] ?? []
            var seen: Set<String> = []
            return Array(diagnostics.compactMap { $0["level"] as? String == "error" ? $0["message"] as? String : nil }
                .map { String($0.prefix(500)) }.filter { seen.insert($0).inserted }.suffix(10))
        }
        // A recording of Chrome's own error page (ERR_BLOCKED_BY_CLIENT), or of three words at most (a loader still
        // showing, as Keeper's "missing ksjsui string"), is no reference: only showing something counts.
        let tokens = { (render: ChromeSmoke.Render?) -> Set<String> in
            let words = Set(render?.tokens.split(separator: " ").map(String.init) ?? [])
            return words.count <= 3 || words.isSuperset(of: ["blocked", "chromium", "err", "client"]) ? [] : words
        }
        let mismatch = { (page: String, shown: Set<String>, expected: Set<String>) in
            "\(page) shows \(expected.intersection(shown).count) of Chrome's \(expected.count) words and controls (missing: "
                + expected.subtracting(shown).sorted().prefix(8).joined(separator: " ") + ")"
        }
        // The errors Chrome's recording has not, normalized.
        let unexpected = { (errors: [Error], chromeErrors: [String]) in
            errors
                // A request for a file the package lacks fails in Chrome too, which reports no extension error for it.
                .filter { ($0 as NSError).domain != WKWebExtension.errorDomain || ($0 as NSError).code != WKWebExtension.Error.resourceNotFound.rawValue }
                .map(\.localizedDescription)
                // WebKit records its refusal of a connect nobody listens to, which the bridge answers with Chrome's port
                // (WEBKIT-GAPS 93): the extension never sees it.
                .filter { !$0.contains("No runtime.onConnect listeners found") }
                // GitHub's macOS runners fail a worker's OffscreenCanvas getImageData (Stylus, AdGuard), which a Mac does not.
                .filter { ProcessInfo.processInfo.environment["LILO_SMOKE_ON_CI"] == nil || !$0.hasPrefix("InvalidStateError: The object is in an invalid state.") }
                // WebKit keeps only the leading text of a console.error, so a Chrome error starting with it is the same.
                .filter { error in
                    let error = normalized(error)
                    return error.isEmpty || !chromeErrors.contains { $0.hasPrefix(error) }
                }
        }

        // The idle check: an extension with a worker and a popup loads again in the idle profile, by batches whose
        // install events and welcome pages are over before they wait. Once a batch's workers went idle (Lilo releases
        // the channel after 20 s, and WebKit unloads the worker after), or after a minute, each one's toolbar button
        // opens its popup on the worker it starts again, as Chrome's recording does on a stopped worker.
        struct Idle {
            let outcome: Outcome
            let package: URL
            let chrome: ChromeSmoke.Recording?
        }
        var idleQueue: [Idle] = [], idleBatch: [Idle] = [], quietSince = Date.distantFuture
        // One at a time: a batch loaded together in the idle profile took gigabytes beside the extension the main pass runs.
        let idleBatchSize = 1
        let advanceIdle = { (draining: Bool) in
            if idleBatch.isEmpty, idleQueue.count >= idleBatchSize || draining && !idleQueue.isEmpty {
                idleBatch = Array(idleQueue.prefix(idleBatchSize))
                idleQueue.removeFirst(idleBatch.count)
                for entry in idleBatch {
                    defer { try? FileManager.default.removeItem(at: entry.package.deletingLastPathComponent()) }
                    do {
                        try await idleRegistry.load(from: entry.package)
                    } catch {
                        entry.outcome.problems.append("idle check: install: \(error)")
                        continue
                    }
                    _ = await idleRegistry.backgrounds.load(entry.outcome.id)
                    _ = await pollUntil(timeout: 10) { idleRegistry.lifecycle.worker(of: entry.outcome.id) == .running }
                }
                // Welcome pages close before the wait: their events would keep the workers awake.
                try await Task.sleep(for: .seconds(3))
                for tab in idleWindow.tabManager.openTabs where tab.id != blank.id { idleWindow.closeTabStateFirst(id: tab.id, undoable: false) }
                idleWindow.activateTabStateFirst(id: blank.id)
                // Chrome's recording opens the popup once before its worker stops, and a popup's first opening may show
                // something else than the next ones (1VPN's upgrade offer): the idle check's popup is a second one too.
                for entry in idleBatch {
                    let button = NSMenuItem()
                    button.representedObject = entry.outcome.id
                    idleWindow.openExtensionFromMenu(button)
                    try await Task.sleep(for: .seconds(5))
                    idleRegistry.delegate.closeOpenActionPopups(reason: "idle check", extensionId: entry.outcome.id)
                }
                for tab in idleWindow.tabManager.openTabs where tab.id != blank.id { idleWindow.closeTabStateFirst(id: tab.id, undoable: false) }
                idleWindow.activateTabStateFirst(id: blank.id)
                quietSince = Date()
            }
            guard !idleBatch.isEmpty else { return }
            let quiet = { idleBatch.allSatisfy { idleRegistry.lifecycle.worker(of: $0.outcome.id) != .running } || Date().timeIntervalSince(quietSince) > 60 }
            if draining { _ = await pollUntil(timeout: 70) { quiet() } }
            guard quiet() else { return }
            for entry in idleBatch {
                let (outcome, id, chrome) = (entry.outcome, entry.outcome.id, entry.chrome)
                defer { finish(outcome) }
                guard let context = idleRegistry.context(for: id) else { continue }
                // An extension may turn its button off, or its popup, on a page it cannot act on.
                let action = idleWindow.tabManager.tabAdapter(for: blank.id).flatMap { context.action(for: $0) }
                guard action?.isEnabled == true, action?.presentsPopup == true else {
                    outcome.idle = "no popup on a blank tab"
                    await idleRegistry.unload(extensionId: id)
                    continue
                }
                outcome.idle = idleRegistry.lifecycle.worker(of: id).map { "\($0)" } ?? "unloaded"
                let errorCount = context.errors.count
                let clicked = Date()
                let button = NSMenuItem()
                button.representedObject = id
                idleWindow.openExtensionFromMenu(button)
                let defaultPopup = (context.webExtension.manifest["action"] as? [String: Any])?["default_popup"] as? String
                var expected = tokens(chrome?.restartPopup ?? chrome?.popup)
                var shown: Set<String> = [], matched = false, restarted = outcome.idle == "running"
                while !(matched && restarted) && Date().timeIntervalSince(clicked) < 40 {
                    try await Task.sleep(for: .milliseconds(250))
                    if !restarted && idleRegistry.lifecycle.worker(of: id) == .running {
                        restarted = true
                        outcome.time("restart", since: clicked, chrome: chrome?.workerRestartMs)
                    }
                    let popup = idleWindow.tabManager.tabAdapter(for: blank.id).flatMap { (idleRegistry.context(for: id) ?? context).action(for: $0)?.popupWebView }
                    // Chrome's recording opens the manifest's popup: one the extension set for the blank tab only has to show something.
                    if let path = popup?.url?.path, let defaultPopup, path != URL(string: defaultPopup, relativeTo: context.baseURL)?.path { expected = [] }
                    guard !matched else { continue }
                    shown = Set(await self.evaluate("(\(probes)).fingerprint()", in: popup) as? [String] ?? [])
                    matched = expected.isEmpty ? !shown.isEmpty : expected.intersection(shown).count * 2 >= expected.count
                    if matched { outcome.time("idlePopup", since: clicked, chrome: chrome?.restartPopup?.ms) }
                }
                // Lilo sees a worker run only once it calls Lilo: one WebKit woke for a popup that works needs nothing more.
                if !restarted && !matched { outcome.problems.append("once idle, its worker does not start again from the toolbar button") }
                if shown.isEmpty {
                    outcome.problems.append("once its worker was idle, the popup renders nothing")
                } else if !matched {
                    outcome.problems.append(mismatch("once its worker was idle, the popup", shown, expected))
                }
                let errors = unexpected(Array((idleRegistry.context(for: id) ?? context).errors.dropFirst(errorCount)), (chrome?.errors ?? []).map(normalized))
                outcome.problems += errors.map { "once its worker was idle, error: \($0)" }
                if !outcome.problems.isEmpty && outcome.details.isEmpty { outcome.details = errorsOf(idleRegistry, id) }
                // What a popup that went another way than Chrome's saw as its tab.
                if !matched, let popup = idleWindow.tabManager.tabAdapter(for: blank.id).flatMap({ (idleRegistry.context(for: id) ?? context).action(for: $0)?.popupWebView }) {
                    _ = await self.evaluate("""
                    chrome.tabs.query({ active: true, currentWindow: true }).then(
                      (tabs) => { window.__liloSmokeTabs = JSON.stringify(tabs.map(({ id, url, status }) => ({ id, url, status }))); },
                      (error) => { window.__liloSmokeTabs = error.message; }), 0
                    """, in: popup)
                    try await Task.sleep(for: .milliseconds(500))
                    outcome.details.append("the popup's active tab: \(await self.evaluate("window.__liloSmokeTabs ?? 'unanswered'", in: popup) as? String ?? "unread")")
                }
                idleRegistry.delegate.closeOpenActionPopups(reason: "idle check", extensionId: id)
                await idleRegistry.unload(extensionId: id)
            }
            idleBatch = []
            for tab in idleWindow.tabManager.openTabs where tab.id != blank.id { idleWindow.closeTabStateFirst(id: tab.id, undoable: false) }
        }

        for (name, id) in selected.map({ ($0.name, $0.id) }) {
            let outcome = Outcome(id: id, name: name)
            var idle: Idle?
            defer {
                if let idle { idleQueue.append(idle) } else { finish(outcome) }
            }
            let package: URL
            do {
                do {
                    package = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: id)
                } catch let error as URLError where error.code == .timedOut {
                    // The store's download host times out now and then under the shards' load: once more before failing.
                    package = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: id)
                }
                try await registry.load(from: package)
            } catch {
                outcome.problems.append("install: \(error)")
                if Self.knownFailures[id] == nil && Self.intermittent[id] == nil { XCTFail("\(name) installs: \(error)") }
                continue
            }
            defer { if idle == nil { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) } }
            guard let context = registry.context(for: id) else {
                outcome.problems.append("does not load")
                if Self.knownFailures[id] == nil && Self.intermittent[id] == nil { XCTFail("\(name) loads") }
                continue
            }
            outcome.version = context.webExtension.version ?? "?"
            let recorded = chromeSmoke.extensions[id]
            // Chrome's behavior with another version says nothing about this one: all its errors count.
            let chrome = recorded?.version == outcome.version ? recorded : nil
            if chrome == nil { outcome.staleChrome = recorded?.version ?? "nothing" }
            var connected = false, workerStarted: Date?
            if context.webExtension.hasBackgroundContent {
                let starting = Date()
                workerStarted = starting
                let loaded = await registry.backgrounds.load(id)
                connected = await pollUntil(timeout: 10) { registry.lifecycle.worker(of: id) == .running }
                if connected { outcome.time("worker", since: starting, chrome: chrome?.workerRestartMs) }
                // Chrome's recording opens the popup once the worker's top-level code has run, which its listener report follows.
                _ = await pollUntil(timeout: 2) { registry.gapEvents.reportedListeners(of: id) != nil }
                if !loaded { outcome.problems.append("the service worker does not load") }
                if !connected { outcome.problems.append("the worker never connects to Lilo") }
                if registry.backgrounds.health(for: id)?.bridgeStatus != "loaded" { outcome.problems.append("degraded") }
            }
            // Resolved as WebKit and Chrome open it: a query or fragment stays one.
            let popupURL = ((context.webExtension.manifest["action"] as? [String: Any])?["default_popup"] as? String)
                .flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: context.baseURL) }
            var popupOpened: Date?
            var phases: [(name: String, count: Int)] = [("the worker's start", 0)]
            if let popupURL {
                phases.append(("the popup", context.errors.count))
                // A popup may wait for its extension's remote configuration first (DuckDuckGo, up to 30 s).
                let expected = tokens(chrome?.popup)
                popupOpened = Date()
                let (shown, matched, closed, matchedAfter) = try await render(window, popupURL, probes: probes, like: expected, timeout: 40)
                // A popup closing the tab it was opened in shows in its own popup, which the idle check opens.
                if closed {
                    outcome.details.append("its popup closes the tab it is opened in")
                } else if shown.isEmpty && chrome?.popupText != false {
                    outcome.problems.append("the popup renders nothing")
                } else if !matched && !expected.isEmpty {
                    outcome.problems.append(mismatch("the popup", shown, expected))
                }
                if let matchedAfter { outcome.time("popup", ms: Int(matchedAfter * 1000), chrome: chrome?.popup?.ms) }
            }
            let chromePage = Set(chrome?.page ?? [])
            // WebKit hands Lilo only the items for every context and the toolbar button's: the page's own context menu
            // gets the others from WebKit, out of the test's reach.
            let chromeMenus = chrome?.menus?.filter { $0.split(separator: ",").contains("all") }.count ?? 0
            let chromeActionMenus = chrome?.menus?.filter { !Set($0.split(separator: ",")).isDisjoint(with: ["action", "browser_action", "page_action"]) }.count ?? 0
            phases.append(("the test page", context.errors.count))
            if !chromePage.isEmpty || chromeMenus + chromeActionMenus > 0 || context.webExtension.manifest["content_scripts"] != nil {
                // Chrome's recording opens the test page once the popup settled, 5 s after it opened at least: an extension
                // setting up its cosmetic filtering after its first start (SBlock, Stop Ads Now) is done by then. Without a
                // popup, a second after the worker started: Chrome registers content scripts in its own process, at once
                // (Cool Ad Popup Blocker's are not yet when WebKit opens the page).
                let ready = popupOpened.map { $0.addingTimeInterval(5) } ?? workerStarted.map { $0.addingTimeInterval(1) }
                if !chromePage.isEmpty, let ready, case let wait = ready.timeIntervalSinceNow, wait > 0 {
                    try await Task.sleep(for: .seconds(wait))
                }
                let tab = try XCTUnwrap(window.createTabStateFirst(url: pageURL))
                let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
                browserContext.context.agentControl.attach(engine, to: nil)
                let page = try XCTUnwrap(engine.view as? WKWebView)
                func leaves(_ items: [NSMenuItem]) -> Int {
                    items.reduce(0) { $0 + ($1.isSeparatorItem ? 0 : $1.submenu.map { leaves($0.items) } ?? 1) }
                }
                // Each kind of change Chrome made, at least half of it.
                let lacking = { (changes: Set<String>) in
                    ["added:", "attribute:", "hidden:"].flatMap { kind in
                        let expected = chromePage.filter { $0.hasPrefix(kind) }
                        return expected.intersection(changes).count * 2 >= expected.count ? [] : expected.subtracting(changes).sorted()
                    }
                }
                var changes: Set<String> = [], menus = 0, actionMenus = 0
                // Without anything of Chrome's to wait for, its content scripts get a second to report their errors.
                let started = Date(), timeout: TimeInterval = chromePage.isEmpty && chromeMenus + chromeActionMenus == 0 ? 1 : 10
                while Date().timeIntervalSince(started) < timeout {
                    try await Task.sleep(for: .milliseconds(250))
                    changes = Set(await evaluate("(\(probes)).pageChanges(\(originalPage))", in: page) as? [String] ?? [])
                    let adapter = window.tabManager.tabAdapter(for: tab.id)
                    menus = adapter.map { leaves(context.menuItems(for: $0)) } ?? 0
                    actionMenus = leaves(context.action(for: adapter)?.menuItems ?? [])
                    if !chromePage.isEmpty || chromeMenus + chromeActionMenus > 0, lacking(changes).isEmpty,
                       menus * 2 >= chromeMenus, actionMenus * 2 >= chromeActionMenus { break }
                }
                if !lacking(changes).isEmpty { outcome.problems.append("the test page lacks Chrome's " + lacking(changes).joined(separator: " ")) }
                if menus * 2 < chromeMenus { outcome.problems.append("its context menus show \(menus) of Chrome's \(chromeMenus) items for all contexts") }
                if actionMenus * 2 < chromeActionMenus {
                    outcome.problems.append("its toolbar button's menu shows \(actionMenus) of Chrome's \(chromeActionMenus) context menu items")
                }
                window.closeTabStateFirst(id: tab.id, undoable: false)
            }
            phases.append(("the options page", context.errors.count))
            if let optionsURL = context.optionsPageURL, chrome == nil || chrome?.options != nil {
                let expected = tokens(chrome?.options)
                let (shown, matched, closed, matchedAfter) = try await render(window, optionsURL, probes: probes, like: expected, timeout: 20)
                if closed {
                    outcome.details.append("its options page closes its own tab")
                } else if shown.isEmpty {
                    outcome.problems.append("the options page renders nothing")
                } else if !matched && !expected.isEmpty {
                    outcome.problems.append(mismatch("the options page", shown, expected))
                }
                if let matchedAfter { outcome.time("options", ms: Int(matchedAfter * 1000), chrome: chrome?.options?.ms) }
            }
            // Each error with the step it came in, to tell a page's last exchanges from its start.
            let steps = phases + [("the end", context.errors.count)]
            let step = { (index: Int) in steps.last { $0.count <= index }?.name ?? "the start" }
            let mainErrors = unexpected(context.errors, (chrome?.errors ?? []).map(normalized))
            outcome.problems += mainErrors.map { message in
                let index = context.errors.firstIndex { $0.localizedDescription == message } ?? 0
                return "error: \(message) (in \(step(index)))"
            }
            if !outcome.problems.isEmpty { outcome.details = errorsOf(registry, id) }
            await registry.unload(extensionId: id)
            // Each extension starts with no page open, as in a new Chrome profile: WebKit injects content
            // scripts into the pages already open when an extension loads, which Chrome never does.
            for tab in window.tabManager.openTabs { window.closeTabStateFirst(id: tab.id, undoable: false) }
            if connected, popupURL != nil, chrome?.restartPopup?.tokens.isEmpty != true {
                idle = Idle(outcome: outcome, package: package, chrome: chrome)
            }
            try await advanceIdle(false)
        }
        while !idleQueue.isEmpty || !idleBatch.isEmpty { try await advanceIdle(true) }
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
        /// Why what its toolbar button opens fails on a paravirtual GPU (WEBKIT-GAPS.md), where the check expects that.
        var paravirtualGap: String?
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
                shows: { window in window.tabManager.openTabs.contains { $0.url?.lastPathComponent == "capture.html" } },
                paravirtualGap: "its popup's canvas.toBlob answers null there (gap 101)")
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
        // The machine's graphics, which the feature checks drawing on a canvas depend on: CI's runners are virtual machines.
        if let probe = window.createTabStateFirst(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))),
           let probePage = window.tabManager.engineTab(for: probe.id)?.view as? WKWebView {
            _ = await pollUntil(timeout: 10) { !probePage.isLoading }
            let readback = await evaluate("""
            (() => { const canvas = Object.assign(document.createElement('canvas'), { width: 4, height: 4 }), context = canvas.getContext('2d');
              context.fillStyle = 'red'; context.fillRect(0, 0, 4, 4);
              try { return 'readback ' + context.getImageData(0, 0, 1, 1).data[0]; } catch (error) { return 'readback ' + error.name; } })()
            """, in: probePage) as? String ?? "unread"
            let snapshot: String
            do { snapshot = "\(try await probePage.takeSnapshot(configuration: nil).size)" } catch { snapshot = "\(error.localizedDescription)" }
            print("LILO_GRAPHICS metal \(MTLCreateSystemDefaultDevice()?.name ?? "none"), canvas \(readback), snapshot \(snapshot)")
            window.closeTabStateFirst(id: probe.id, undoable: false)
        }
        let paravirtualGPU = MTLCreateSystemDefaultDevice()?.name.contains("Paravirtual") ?? true
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
            // What a failing check saw, to tell an extension's failure from the machine's.
            let diagnosis = { () async -> String in
                let state = await self.evaluate("""
                JSON.stringify({ url: location.href, title: document.title, videos: document.querySelectorAll('video').length,
                  controllers: document.querySelectorAll('vsc-controller').length, text: document.body?.innerText.slice(0, 120) })
                """, in: page) as? String ?? "unread"
                let worker = registry.lifecycle.worker(of: feature.id).map { "\($0)" } ?? "none"
                let errors = context.errors.suffix(4).map { String($0.localizedDescription.prefix(160)) }
                // Lilo's console relay names the page each message came from.
                let consoles = (registry.backgroundDiagnosticsSnapshots().first { $0["id"] as? String == feature.id }?["pageDiagnostics"] as? [[String: Any]] ?? [])
                    .suffix(4).map { "\($0["source"] ?? "?"): \(String(describing: $0["message"] ?? "").prefix(200))" }
                return "page \(state), worker \(worker), tabs \(window.tabManager.openTabs.compactMap { $0.url?.absoluteString }), errors \(errors), consoles \(consoles)"
            }
            if let shows = feature.shows {
                let shown = await pollUntil(timeout: 30) { shows(window) }
                if let gap = feature.paravirtualGap, paravirtualGPU {
                    if shown { XCTFail("\(feature.name) now opens what its toolbar button opens on a paravirtual GPU: drop its gap (\(gap))") }
                } else if !shown {
                    XCTFail("\(feature.name) opens what its toolbar button opens: \(await diagnosis())")
                }
            }
            let checked = await holds(feature.check)
            if !checked { XCTFail("\(feature.name) does its part on the page: \(await diagnosis())") }
            if feature.menu, let adapter = window.tabManager.tabAdapter(for: tab.id) {
                let added = await pollUntil(timeout: 10) { !context.menuItems(for: adapter).isEmpty }
                if !added { XCTFail("\(feature.name) adds its context menu entry: \(await diagnosis())") }
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
