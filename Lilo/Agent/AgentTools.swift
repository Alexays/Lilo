import Foundation
import WebKit

/// The tools an agent sees, named and shaped like Claude in Chrome's so agents need nothing new.
@MainActor
enum AgentTools {
    static let definitions: [[String: Any]] = tabAndPageDefinitions + AgentInteractionTools.definitions + AgentDevTools.definitions

    private static let tabAndPageDefinitions: [[String: Any]] = [
        tool("tabs_context_mcp", """
            Get context information about your tab group in Lilo's Agents space. Returns all tab IDs inside the group if it \
            exists. You must get the context at least once before using other browser tools so you know what tabs exist. \
            Each new conversation should create its own new tab (using tabs_create_mcp) rather than reusing existing tabs, \
            unless the user explicitly asks to use an existing tab. Other agents have their own group, but subagents of one \
            session share it: create your own tab and use only the tabs you created or were given. The user's private tabs \
            are never listed nor reachable. An error starting with [needs_user] means only the user can unblock it: ask them.
            """, [
                "createIfEmpty": prop("boolean", "Creates your tab group with an empty tab if none exists."),
                "title": prop("string", "What you are working on, in 2 to 4 words (\"Signup flow\", \"CSV export bug\"): your group's name the user sees.")
            ]),
        tool("tabs_create_mcp", """
            Creates a new empty tab in your tab group, in the background. Tabs you create are yours to clean up: \
            close each one with tabs_close_mcp as soon as you no longer need it.
            """, [
                "title": prop("string", "What you are working on, in 2 to 4 words: your group's name the user sees."),
                "isolated": prop("boolean", """
                    True for a tab in your own private space: it shares no cookie, storage or sign-in with your other \
                    tabs, like a fresh visitor or a second user. Your isolated tabs share one cookie jar, gone when you disconnect.
                    """)
            ]),
        tool("tabs_close_mcp", "Closes a tab of your tab group.", ["tabId": prop("number", "The tab to close.")], required: ["tabId"]),
        tool("navigate", """
            Navigate a tab to a URL, go "back" or "forward" in its history, or "reload". Waits for redirects, \
            script ones included, and for the page to settle (loaded, no request in flight, DOM still), then gives the \
            final URL and title.
            A JSON or plain text response comes back in the reply.
            """, [
                "url": prop("string", "The URL to load (the scheme defaults to https://), or \"back\", \"forward\" or \"reload\"."),
                "tabId": prop("number", "The tab to navigate.")
            ], required: ["url", "tabId"]),
        tool("read_page", """
            Get an accessibility tree of the page: each element as role, name and a ref like [ref_N] that the other \
            tools accept. Use filter "interactive" for clickable and typable elements only. Iframes follow the page, \
            their refs prefixed by their frame (f1a2b3_ref_N).
            """, [
                "tabId": prop("number", "The tab to read."),
                "filter": ["type": "string", "enum": ["interactive", "all"], "description": "\"all\" (default) or \"interactive\"."],
                "ref_id": prop("string", "Read only this element's subtree."),
                "depth": prop("number", "Maximum tree depth (default 15)."),
                "max_chars": prop("number", "Maximum characters of output (default 50000).")
            ], required: ["tabId"]),
        tool("find", "Find elements whose role, name or text contains `query`, case-insensitively. Returns up to 20 refs, of shown elements only.", [
            "query": prop("string", "Text to look for."), "tabId": prop("number", "The tab to search.")
        ], required: ["query", "tabId"]),
        tool("get_page_text", "Extract the visible text of the page, article or main content first.", [
            "tabId": prop("number", "The tab to read."), "max_chars": prop("number", "Maximum characters of output (default 50000).")
        ], required: ["tabId"]),
        tool("form_input", """
            Set the value of a form element (input, textarea, select, checkbox, contenteditable) by ref. A native date, time \
            or color picker draws outside the page and never shows in a screenshot: set those inputs here instead of clicking.
            """, [
            "ref": prop("string", "The element's ref from read_page or find."),
            "value": ["type": ["string", "boolean", "number"], "description": "The value; a boolean for a checkbox."],
            "tabId": prop("number", "The tab.")
        ], required: ["ref", "value", "tabId"]),
        tool("javascript_tool", """
            Execute JavaScript in the page. Top-level await works, and the value of the last expression is returned. \
            It runs once, in the page as it is: for code that runs before the page's own scripts on every load, \
            like a guard or a stub, use emulate initScript. The user's approval covers clicks, Enter and fetch, not \
            this code: never use it to do what the user denied or has not allowed yet.
            """, [
                "action": ["type": "string", "enum": ["javascript_exec"], "description": "Always \"javascript_exec\"."],
                "text": prop("string", "The JavaScript code to run."),
                "timeout": prop("number", "Seconds before the call is stopped, 60 by default, up to 600: for a long fetch or wait."),
                "tabId": prop("number", "The tab.")
            ], required: ["action", "text", "tabId"]),
        tool("fetch", """
            Send an HTTP request from a tab, as its page would with fetch(): from its origin, under its CORS rules, \
            with its profile's cookies (credentials). A relative URL resolves against the page. Returns status, final \
            URL, response headers (never Set-Cookie or Authorization) and the body, cut at maxBytes with truncated: true. \
            In one of the user's profiles, a request other than GET or HEAD waits for the user's approval.
            """, [
                "url": prop("string", "The URL to request."),
                "method": prop("string", "GET by default."),
                "headers": ["type": "object", "description": "Request headers by name. The browser sets Cookie itself."],
                "body": ["type": ["string", "object", "array"], "description": "The request body: a string, or JSON for an object."],
                "credentials": ["type": "string", "enum": ["same-origin", "include", "omit"],
                                "description": "Which requests carry cookies, as fetch's option: same-origin by default, include for a cross-origin API that allows them."],
                "responseType": ["type": "string", "enum": ["text", "json", "base64"], "description": "How the body comes back: text (default), parsed json, or base64 for binary."],
                "maxBytes": prop("number", "Most bytes of the body read, 1048576 (1 MB) by default, up to 10485760."),
                "tabId": prop("number", "The tab whose page sends the request.")
            ], required: ["url", "tabId"])
    ]

    static func call(
        _ name: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async throws -> [AgentContent] {
        switch name {
        case "tabs_context_mcp":
            nameFolder(session, arguments["title"], control: control)
            let create = arguments["createIfEmpty"] as? Bool ?? false
            let isolated = control.isolatedTabs(of: session)
            let (folderId, space, host) = try control.agentFolder(for: session, create: create && isolated.isEmpty)
            guard folderId != nil || !isolated.isEmpty else {
                return [.text("No tab group exists yet. Call tabs_context_mcp with createIfEmpty: true, or tabs_create_mcp.")]
            }
            var tabs = folderId.map { control.tabs(inFolder: $0, spaceId: space.id) } ?? []
            if tabs.isEmpty, isolated.isEmpty, create { tabs = [try control.createTab(inFolder: folderId, space: space, host: host)] }
            control.refreshControlledTabs()
            let entry = { (tab: Tab) -> [String: Any] in ["tabId": control.number(for: tab.id), "title": tab.title, "url": tab.url?.absoluteString ?? ""] }
            let available = tabs.map(entry) + isolated.map { entry($0).merging(["isolated": true]) { $1 } }
            return [.text(json(["availableTabs": available, "tabGroupId": folderId?.uuidString ?? NSNull()]))]
        case "tabs_create_mcp":
            nameFolder(session, arguments["title"], control: control)
            if arguments["isolated"] as? Bool == true {
                guard let (space, host) = try control.isolatedSpace(for: session, create: true) else {
                    throw AgentToolError("Could not create the private space")
                }
                let tab = try control.createTab(inFolder: nil, space: space, host: host)
                control.refreshControlledTabs()
                return [.text("Created new isolated tab, sharing no cookie or storage with your other tabs. Tab ID: \(control.number(for: tab.id))")]
            }
            let (folderId, space, host) = try control.agentFolder(for: session, create: true)
            guard let folderId else { throw AgentToolError("Could not create the tab folder") }
            let tab = try control.createTab(inFolder: folderId, space: space, host: host)
            control.refreshControlledTabs()
            return [.text("Created new tab. Tab ID: \(control.number(for: tab.id))")]
        case "tabs_close_mcp":
            let (tab, _) = try control.agentTab(arguments["tabId"], session: session, evenUnresponsive: true)
            let number = control.number(for: tab.id)
            try control.closeTab(tab)
            control.refreshControlledTabs()
            // The last blank tab of a space stays open.
            if let state = control.context?.browserState, let spaceId = state.owningSpaceId(forTab: tab.id),
               state.structuralProjection(forSpace: spaceId)?.tabs.contains(where: { $0.id == tab.id && !$0.isClosed }) == true {
                throw AgentToolError("Tab \(number) did not close: it is the last blank tab of its space")
            }
            if control.isolatedTabs(of: session).isEmpty { control.dropIsolatedSpace(of: session) }
            return [.text("Closed tab \(number)")]
        case "navigate":
            let (tab, engine) = try control.agentTab(arguments["tabId"], session: session)
            let target = (arguments["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let before = engine.currentURL
            var requested: URL?
            switch target {
            case "back": engine.goBack()
            case "forward": engine.goForward()
            case "reload": engine.reload()
            default:
                let hasScheme = target.contains("://") || ["about:", "data:"].contains { target.hasPrefix($0) }
                // A dev server answers plain HTTP: "localhost:3000" means http://localhost:3000.
                let isLocal = ["localhost", "127.0.0.1", "[::1]"].contains { target.hasPrefix($0) }
                guard !target.isEmpty, let url = URL(string: hasScheme ? target : (isLocal ? "http://" : "https://") + target) else {
                    throw AgentToolError("Invalid URL: \(target)")
                }
                requested = url
                engine.loadURL(url)
            }
            let settled = await waitForLoad(engine, capture: control.captures[tab.id])
            try Task.checkCancellation()
            var reply = "Navigated to \(engine.currentURL?.absoluteString ?? "") - \(engine.currentTitle ?? "")"
            if !settled { reply += "\nWarning: the page was still loading or changing 5 s after its load: take a screenshot before relying on it" }
            // A single-page app can hold or undo a navigation: the agent must not take the old page for the new one.
            if target != "reload", engine.currentURL == before, requested.map({ $0 != before }) ?? true {
                reply += "\nWarning: the URL did not change, the tab still shows the page it showed before"
            }
            // A JSON or plain text response is the answer itself: it comes back with the navigation.
            let body = try? await engine.wkWebView.callAsyncJavaScript(
                "return /json|^text\\/plain/.test(document.contentType) ? document.body?.innerText.slice(0, 50000) : null",
                contentWorld: AgentInput.world
            ) as? String
            return [.text(body.map { reply + "\n\n" + $0 } ?? reply)]
        case "read_page":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            var options: [String: Any] = ["filter": arguments["filter"] as? String ?? "all"]
            options["refId"] = arguments["ref_id"]
            options["depth"] = arguments["depth"]
            options["maxChars"] = arguments["max_chars"]
            return [.text(try await readFrames(engine, options))]
        case "find":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            return [.text(try await findInFrames(engine, arguments["query"] as? String ?? ""))]
        case "get_page_text":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            return [.text(try await page(engine, "text", ["maxChars": arguments["max_chars"] ?? 50000]) as? String ?? "")]
        case "form_input":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            let ref = arguments["ref"] as? String ?? ""
            let frame = try await frame(holding: ref, in: engine)
            return [.text(try await page(engine, "setValue", ["ref": ref, "value": arguments["value"] ?? ""], in: frame) as? String ?? "")]
        case "javascript_tool":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            return [.text(try await runJavaScript(arguments["text"] as? String ?? "", in: engine))]
        case "fetch":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            guard let url = arguments["url"] as? String, !url.isEmpty else { throw AgentToolError("url is required") }
            let method = (arguments["method"] as? String ?? "GET").uppercased()
            // In one of the user's profiles the request carries their cookies: it may act for them, as a click does.
            if !["GET", "HEAD"].contains(method), !engine.isPrivateBrowsing, session.profileId != nil {
                let target = URL(string: url, relativeTo: engine.currentURL)?.absoluteString ?? url
                try await control.approveConsequentialAction("fetch", label: "\(method) \(target)", frame: nil, engine: engine, session: session)
            }
            var options: [String: Any] = [
                "url": url, "method": method,
                "maxBytes": min(max((arguments["maxBytes"] as? NSNumber)?.intValue ?? 1 << 20, 1), 10 << 20)
            ]
            options["headers"] = arguments["headers"] as? [String: Any]
            options["credentials"] = arguments["credentials"] as? String
            options["responseType"] = arguments["responseType"] as? String
            if let body = arguments["body"], !(body is NSNull) { options["body"] = body as? String ?? json(body) }
            if !["GET", "HEAD", "OPTIONS"].contains(method) { AgentCallSent.current?.write = true }
            return [.text(json(try await page(engine, "request", options) ?? [:]))]
        default:
            if let content = try await AgentInteractionTools.call(name, arguments: arguments, session: session, control: control) { return content }
            if let content = try await AgentDevTools.call(name, arguments: arguments, session: session, control: control) { return content }
            throw AgentToolError("Unknown tool: \(name)")
        }
    }

    /// The task an agent names, its folder's name from then on.
    private static func nameFolder(_ session: AgentSession, _ title: Any?, control: AgentControl) {
        guard let title = (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
        session.title = String(title.prefix(60))
        control.renameFolder(of: session)
    }

    private static let pageScript = Bundle.appResourceURL("AgentPage", extension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    /// Calls a function of AgentPage.js in `frame` (the main one by default), injecting the script first
    /// into a document that lacks it.
    static func page(_ engine: WKWebViewTab, _ method: String, _ arguments: [String: Any], in frame: WKFrameInfo? = nil) async throws -> Any? {
        let call = "return window.__liloAgent[method](args)"
        let parameters: [String: Any] = ["method": method, "args": arguments]
        do {
            let result = try await engine.wkWebView.callAsyncJavaScript(
                "if (!window.__liloAgent) return '__lilo_missing'\n" + call, arguments: parameters, in: frame, contentWorld: AgentInput.world
            )
            guard result as? String == "__lilo_missing" else { return result }
            return try await engine.wkWebView.callAsyncJavaScript(
                pageScript + "\n" + call, arguments: parameters, in: frame, contentWorld: AgentInput.world
            )
        } catch {
            throw AgentToolError(scriptErrorMessage(error))
        }
    }

    /// The tab's live subframes, once each, by the ref prefix their script took. A frame that went
    /// away, or navigated twice, is skipped.
    static func subframes(of engine: WKWebViewTab) async -> [(prefix: String, frame: WKFrameInfo)] {
        var found: [(prefix: String, frame: WKFrameInfo)] = []
        for frame in engine.subframes {
            guard let prefix = try? await page(engine, "prefix", [:], in: frame) as? String, !prefix.isEmpty,
                  !found.contains(where: { $0.prefix == prefix }) else { continue }
            found.append((prefix, frame))
        }
        return found
    }

    /// The subframe that holds `ref`, nil for the main frame's refs.
    static func frame(holding ref: String, in engine: WKWebViewTab) async throws -> WKFrameInfo? {
        guard !ref.hasPrefix("ref_"), let cut = ref.range(of: "_ref_") else { return nil }
        let prefix = String(ref[..<cut.lowerBound]) + "_"
        guard let frame = await subframes(of: engine).first(where: { $0.prefix == prefix })?.frame else {
            throw AgentToolError("Element \(ref) not found: its frame is gone, read the page again")
        }
        return frame
    }

    /// read_page over the main frame, then each frame with something to show, within one budget.
    private static func readFrames(_ engine: WKWebViewTab, _ options: [String: Any]) async throws -> String {
        if let ref = options["refId"] as? String, let frame = try await frame(holding: ref, in: engine) {
            return try await page(engine, "readPage", options, in: frame) as? String ?? ""
        }
        var output = try await page(engine, "readPage", options) as? String ?? ""
        let budget = (options["maxChars"] as? NSNumber)?.doubleValue ?? 50000
        for (_, frame) in await subframes(of: engine) where Double(output.count) < budget {
            let rest = options.merging(["maxChars": budget - Double(output.count)]) { $1 }
            guard let text = try? await page(engine, "readPage", rest, in: frame) as? String, !text.isEmpty else { continue }
            output += "\n\n" + text
        }
        return output
    }

    /// find over the main frame and its frames, 20 matches at most.
    private static func findInFrames(_ engine: WKWebViewTab, _ query: String) async throws -> String {
        var matches = try await page(engine, "find", ["query": query]) as? [String] ?? []
        for (_, frame) in await subframes(of: engine) where matches.count < 20 {
            matches += (try? await page(engine, "find", ["query": query, "limit": 20 - matches.count], in: frame) as? [String]) ?? []
        }
        return matches.isEmpty ? "No element matches \"\(query)\"" : matches.joined(separator: "\n")
    }

    /// REPL semantics in the page's own world: `return` goes before the last statement when it starts an
    /// expression, so `document.title`, `a; 'ok'` or `await fetch(u).then(r => r.status)` give their value.
    private static func runJavaScript(_ code: String, in engine: WKWebViewTab) async throws -> String {
        // A runtime error comes back as a value: only a body that does not compile may be tried again.
        let serialize = """
            let v
            try { v = await (async () => { %@
            })() } catch (e) { return { __liloError: e instanceof Error ? `${e.name}: ${e.message}` : String(e) } }
            if (v === undefined) return 'undefined'
            if (v instanceof Node) return v.outerHTML?.slice(0, 5000) ?? String(v)
            if (typeof v === 'function') return v.toString()
            try { return JSON.stringify(v, null, 2) ?? String(v) } catch { return String(v) }
            """
        let declarations: Set = ["const", "let", "var", "if", "for", "while", "do", "switch", "try", "function", "class",
                                 "return", "throw", "import", "export"]
        // The last statement first; an earlier start only when it does not compile alone, like a `.then()` line.
        var bodies: [String] = []
        var endsWithBlock = false
        for start in statementStarts(code).prefix(3) {
            let statement = code[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            // A whole word: `returned` or `tryCount` are expressions.
            let keyword = String(statement.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
            guard !declarations.contains(keyword), !statement.hasPrefix("}") else {
                endsWithBlock = ["if", "for", "while", "do", "switch", "try"].contains(keyword)
                break
            }
            bodies.append(String(code[..<start]) + "return " + code[start...])
        }
        bodies.append(code)
        var lastError: Error?
        for body in bodies {
            do {
                let result = try await engine.wkWebView.callAsyncJavaScript(
                    serialize.replacingOccurrences(of: "%@", with: body), arguments: [:], contentWorld: .page
                )
                if let failure = (result as? [String: Any])?["__liloError"] as? String { throw AgentToolError(failure) }
                let value = result as? String ?? "undefined"
                // Unlike a console, the code runs in a function: a block's own value is lost.
                if value == "undefined", body == code, endsWithBlock {
                    return "undefined (the code ends with a block statement, whose value is not returned: end it with an expression)"
                }
                return value
            } catch let failure as AgentToolError {
                throw failure
            } catch {
                lastError = error
                // A body that does not compile ran nothing: the added `return` was wrong, try the next one.
                guard scriptErrorMessage(error).contains("SyntaxError") else { break }
            }
        }
        throw AgentToolError(lastError.map(scriptErrorMessage) ?? "JavaScript failed")
    }

    /// Top-level statement starts in `code`, last first: after a `;`, line break or closing brace outside brackets, strings,
    /// templates, regexes and comments, skipping comment-only ones. A brace closing an expression (object literal) yields a bad start.
    private static func statementStarts(_ code: String) -> [String.Index] {
        let chars = Array(code.utf8)
        var starts = [0]
        var depth = 0
        // The depth inside each open `${` of a template: its closing brace goes back into the template.
        var templates: [Int] = []
        var i = 0
        // Leaves `i` on the template's closing backtick, or on the brace of a `${` it opens.
        func skipTemplate() {
            while i < chars.count, chars[i] != UInt8(ascii: "`") {
                if chars[i] == UInt8(ascii: "\\") {
                    i += 1
                } else if chars[i] == UInt8(ascii: "$"), i + 1 < chars.count, chars[i + 1] == UInt8(ascii: "{") {
                    i += 1
                    depth += 1
                    templates.append(depth)
                    return
                }
                i += 1
            }
        }
        // A slash opens a regex where a value is expected: first, or after an operator, a bracket or a keyword.
        func opensRegex() -> Bool {
            var j = i - 1
            while j >= 0, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(chars[j]) { j -= 1 }
            guard j >= 0 else { return true }
            let isWord = { (c: UInt8) in c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || (c >= 48 && c <= 57) || ((c | 0x20) >= 97 && (c | 0x20) <= 122) }
            if isWord(chars[j]) {
                var k = j
                while k > 0, isWord(chars[k - 1]) { k -= 1 }
                let word = String(bytes: chars[k...j], encoding: .utf8) ?? ""
                return ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"].contains(word)
            }
            return ![UInt8(ascii: ")"), UInt8(ascii: "]")].contains(chars[j])
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case UInt8(ascii: "'"), UInt8(ascii: "\""):
                i += 1
                while i < chars.count, chars[i] != c {
                    if chars[i] == UInt8(ascii: "\\") { i += 1 }
                    i += 1
                }
            case UInt8(ascii: "`"):
                i += 1
                skipTemplate()
            case UInt8(ascii: "/") where i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "/"):
                while i + 1 < chars.count, chars[i + 1] != UInt8(ascii: "\n") { i += 1 }
            case UInt8(ascii: "/") where i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "*"):
                i += 2
                while i + 1 < chars.count, !(chars[i] == UInt8(ascii: "*") && chars[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i += 1
            case UInt8(ascii: "/") where opensRegex():
                // A slash in a character class does not end the regex.
                var inClass = false
                i += 1
                while i < chars.count, chars[i] != UInt8(ascii: "\n"), inClass || chars[i] != UInt8(ascii: "/") {
                    switch chars[i] {
                    case UInt8(ascii: "\\"): i += 1
                    case UInt8(ascii: "["): inClass = true
                    case UInt8(ascii: "]"): inClass = false
                    default: break
                    }
                    i += 1
                }
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"): depth = max(depth - 1, 0)
            case UInt8(ascii: "}") where templates.last == depth:
                templates.removeLast()
                depth -= 1
                i += 1
                skipTemplate()
            case UInt8(ascii: "}"):
                depth = max(depth - 1, 0)
                if depth == 0 { starts.append(i + 1) }
            case UInt8(ascii: ";") where depth == 0, UInt8(ascii: "\n") where depth == 0: starts.append(i + 1)
            default: break
            }
            i += 1
        }
        let utf8 = code.utf8
        return starts.reversed().compactMap { offset in
            let index = utf8.index(utf8.startIndex, offsetBy: min(offset, chars.count))
            let statement = code[index...].prefix { $0 != ";" && $0 != "\n" }.trimmingCharacters(in: .whitespaces)
            return statement.isEmpty || statement.hasPrefix("//") || statement.hasPrefix("/*") ? nil : index
        }
    }

    private static func scriptErrorMessage(_ error: Error) -> String {
        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    /// Resolves true once the DOM held still for `quietMs`, false at `maxMs` or before the document completes.
    private static let domQuietScript = """
        return await new Promise(resolve => {
          let quiet
          const done = settled => { observer.disconnect(); clearTimeout(quiet); clearTimeout(cap); resolve(settled) }
          const wait = () => { clearTimeout(quiet); quiet = setTimeout(() => done(document.readyState === 'complete'), quietMs) }
          const observer = new MutationObserver(wait)
          observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true })
          const cap = setTimeout(() => done(false), maxMs)
          wait()
        })
        """

    /// How long the DOM, then the network, must hold still for a page to count as settled.
    static var settleQuiet = (dom: Duration.milliseconds(200), network: Duration.milliseconds(500))

    /// Waits for the page to settle: no navigation running, no request in flight and the DOM still for a
    /// moment, so script redirects and pages that render after their load come out whole. Up to 30 s for the
    /// loads and 5 s past the last one to settle: past that the agent gets the page as it is, and false.
    @discardableResult
    static func waitForLoad(_ engine: WKWebViewTab, capture: AgentCapture?) async -> Bool {
        let start = ContinuousClock.now
        let deadline = start + .seconds(30)
        // A load can take a moment to start after the request.
        while !engine.isLoading, !Task.isCancelled, ContinuousClock.now - start < .milliseconds(500) { try? await Task.sleep(for: .milliseconds(20)) }
        var settleBy: ContinuousClock.Instant?
        // A cancelled sleep returns at once: without the check the loop would spin until the deadline.
        while ContinuousClock.now < deadline, !Task.isCancelled {
            // A redirect made by script starts a new load, with its own time to settle.
            if engine.isLoading {
                settleBy = nil
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let limit = settleBy ?? min(ContinuousClock.now + .seconds(5), deadline)
            settleBy = limit
            guard ContinuousClock.now < limit else { return false }
            if capture?.indexByLoad.isEmpty == false {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let maxMs = Int((limit - ContinuousClock.now) / .milliseconds(1))
            let asked = engine.currentURL
            // The page's own timer ends the wait, but a document that goes away takes it along. Nil: the script
            // failed to run.
            let quiet = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
                var answered = false
                let answer = { (value: Bool?) in
                    guard !answered else { return }
                    answered = true
                    continuation.resume(returning: value)
                }
                engine.wkWebView.callAsyncJavaScript(
                    domQuietScript, arguments: ["quietMs": settleQuiet.dom / .milliseconds(1), "maxMs": maxMs], in: nil, in: AgentInput.world
                ) { answer((try? $0.get()) as? Bool) }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(maxMs + 100)) { answer(false) }
            }
            // A document that went away is a new load, which may have finished before this resumes: that page
            // settles in turn. A script that cannot run in the page it was asked in ends the wait.
            guard let quiet else {
                if engine.isLoading || engine.currentURL != asked { continue }
                return true
            }
            guard quiet, !engine.isLoading, capture?.indexByLoad.isEmpty != false else { continue }
            // An app that boots in steps (a splash, then a config fetch from a timer) is quiet between them.
            let idle = capture.map { ContinuousClock.now - $0.lastNetworkActivity } ?? .seconds(1)
            if idle >= settleQuiet.network { return true }
            try? await Task.sleep(for: settleQuiet.network - idle)
        }
        return false
    }

    /// Fragments allowed: a fetch body or a command's result can be a bare number, string or boolean, which
    /// JSONSerialization otherwise rejects with an exception, not an error.
    static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }
}
