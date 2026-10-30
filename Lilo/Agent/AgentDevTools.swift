import Foundation
import WebKit

/// Devtools beyond Claude in Chrome's set, mostly through the tab's own Web Inspector.
@MainActor
enum AgentDevTools {
    static let definitions: [[String: Any]] = [
        AgentTools.tool("devtools_command", """
            Send a command of WebKit's Web Inspector protocol to a tab (not the Chrome DevTools Protocol: \
            domains and commands differ). Returns the result as JSON. Without method, lists every command \
            this WebKit supports. Events of the domains you send commands to are kept for devtools_events. \
            The user's approval covers clicks, Enter and fetch, not these commands: never use them to do what the \
            user denied or has not allowed yet.
            """, [
                "method": AgentTools.prop("string", "Domain.command, for example Runtime.evaluate or DOM.getDocument."),
                "params": ["type": "object", "description": "The command's parameters."],
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["tabId"]),
        AgentTools.tool("devtools_events", """
            Read the Web Inspector protocol events of a tab, oldest first, as JSON lines. Only events of \
            domains you sent a command to with devtools_command are kept (send Domain.enable first).
            """, [
                "prefix": AgentTools.prop("string", "Only events whose name starts with this, like Network. or Console.messageAdded."),
                "limit": AgentTools.prop("number", "Most recent events to return, 50 by default."),
                "clear": AgentTools.prop("boolean", "Empty the buffer after reading."),
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["tabId"]),
        AgentTools.tool("network_mock", """
            Intercept a tab's requests whose URL matches a regex: answer with a mock response, fail them, \
            rewrite them, or only delay them (delayMs, to simulate latency). The first matching rule wins; \
            rules last until removed or until the tab leaves your folder. Actions: add, remove, list (each \
            rule with its hits and lastError), clear. A rule with no outcome lets its requests through: added \
            first, it exempts them from the rules after it. Read-only browsing: allow the reads you need, like \
            {urlPattern: "/api/search", methods: ["POST"]}, then fail the rest of the writes with \
            {urlPattern: "^https://api\\.example\\.com/", methods: ["POST", "PUT", "PATCH", "DELETE"], error: "AccessControl"}. \
            WebKit intercepts by URL only: methods filters after, so a GET the pattern matches is intercepted too, and an \
            intercepted <link rel=preload> fires error. Keep urlPattern to the API, never the page's own files. bodyPattern \
            and bodyJson filter after too, on the body as WebKit shows it: text from fetch, XHR, sendBeacon and form posts \
            (strings, JSON, URLSearchParams, FormData's text fields). A Blob or File body, or a file part, is not in it.
            """, [
                "action": ["type": "string", "enum": ["add", "remove", "list", "clear"]],
                "id": AgentTools.prop("number", "The rule to remove."),
                "urlPattern": AgentTools.prop("string", "A JavaScript regex tested against the full URL."),
                "methods": ["type": "array", "items": ["type": "string"], "description": "Only requests of these HTTP methods, like [\"POST\"]."],
                "bodyPattern": AgentTools.prop("string", "Only requests whose body, as text, matches this JavaScript regex."),
                "bodyJson": ["type": "object", "description": """
                    Only requests whose JSON body has all these top-level fields. A string is a regex over the field's value: \
                    {operationName: "^GetUser$"} for one GraphQL operation, {query: "^\\s*mutation\\b"} for every mutation. \
                    Other values must be equal. A batch (a JSON array) matches when one of its items does.
                    """],
                "stage": ["type": "string", "enum": ["request", "response"],
                          "description": "request (default): before it is sent. response: replace the real response."],
                "response": ["type": "object", "description": """
                    The mock: status (200), statusText, headers, mimeType (text/plain, or the file's), and one of body \
                    (text), bodyBase64, or path: an absolute local path, read on each request. $1 and up in path take \
                    urlPattern's groups, to serve a folder: /assets/([^?]*) with /abs/dist/assets/$1. A missing file answers 404. \
                    The user allows the file, or the folder, first.
                    """],
                "error": ["type": "string", "enum": ["General", "AccessControl", "Cancellation", "Timeout"],
                          "description": "Fail the request instead."],
                "modify": ["type": "object", "description": "Send the request changed instead: url, method, headers, postData."],
                "delayMs": AgentTools.prop("number", "Wait this long before applying the outcome."),
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["action", "tabId"]),
        AgentTools.tool("network_response", """
            Requests of a tab in full: method, status, headers, request body, timings, sizes, cache source and \
            response body. ttfbMs runs from the request's start to its first response byte and durationMs to its \
            last, both as the network saw them; startMs is when it started after the first listed. One request by \
            default, the most recent matching or requestId; all lists every matching one, oldest first; har saves \
            them as a HAR file. Only requests made after the first devtools tool on the tab are known: reload to \
            capture them.
            """, [
                "url": AgentTools.prop("string", "The URL, or part of it; for one request, the most recent with exactly this URL wins, else the most recent containing it."),
                "requestId": AgentTools.prop("string", "One request by its id, from read_network_requests or all, as a string: \"0.16620\"."),
                "responseBody": AgentTools.prop("boolean", "false leaves the response body out, for a request body alone."),
                "method": AgentTools.prop("string", "Only requests of this method, like POST."),
                "all": AgentTools.prop("boolean", "Every matching request (the last 200), not just the most recent."),
                "har": AgentTools.prop("boolean", "Save every matching request, bodies whole, as a HAR file and return its path."),
                "max_chars": AgentTools.prop("number", """
                    Maximum characters of each body (default 5000 for one request, 2000 with all). A longer JSON body \
                    also comes with bodyShape: its keys and types, and each array's length.
                    """),
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["tabId"]),
        AgentTools.tool("cookies", """
            Read and change the cookies of a tab's profile, HttpOnly ones included. get, delete and clear reach \
            only the cookies sent to the sites your tabs show. Actions: get (filter by url or domain), set, \
            delete (name and domain), clear (every cookie of a domain; a domain is required).
            """, [
                "action": ["type": "string", "enum": ["get", "set", "delete", "clear"]],
                "url": AgentTools.prop("string", "get: the cookies a request to this URL would send."),
                "domain": AgentTools.prop("string", "get, delete, clear: this domain and its subdomains."),
                "name": AgentTools.prop("string", "delete: the cookie's name."),
                "cookie": ["type": "object", "description": """
                    set: name, value, domain, path (/), expires (unix seconds, a session cookie without), \
                    httpOnly, secure, sameSite (Lax, Strict or None).
                    """],
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["action", "tabId"]),
        AgentTools.tool("emulate", """
            Make a tab look like another environment. Only the fields you pass change, null resets one, \
            reset: true resets all; everything resets when the tab leaves your folder. Returns what is set. \
            The viewport size is resize_window. For a cold load, set cache: false then navigate reload. WebKit has \
            no CPU or bandwidth throttling: network_mock with delayMs adds latency to the requests it matches.
            """, [
                "userAgent": ["type": ["string", "null"], "description": "The User-Agent header and navigator.userAgent, from the next load."],
                "deviceScaleFactor": ["type": ["number", "null"], "description": "devicePixelRatio, like 2 or 3."],
                "colorScheme": ["type": ["string", "null"], "enum": ["light", "dark", NSNull()] as [Any],
                                "description": "prefers-color-scheme: the light or dark theme of a site that follows the system."],
                "reducedMotion": ["type": ["string", "null"], "enum": ["reduce", "no-preference", NSNull()] as [Any], "description": "prefers-reduced-motion."],
                "contrast": ["type": ["string", "null"], "enum": ["more", "no-preference", NSNull()] as [Any],
                             "description": "prefers-contrast: more for a high contrast theme, with either colorScheme."],
                "media": ["type": ["string", "null"], "enum": ["print", "screen", NSNull()] as [Any], "description": "The CSS media type."],
                "javascript": ["type": ["boolean", "null"], "description": "false runs pages without JavaScript."],
                "images": ["type": ["boolean", "null"], "description": "false loads no images."],
                "cache": ["type": ["boolean", "null"], "description": "false bypasses the HTTP cache."],
                "extraHeaders": ["type": ["object", "null"], "description": "Headers added to every request, by name."],
                "initScript": ["type": ["string", "null"], "description": """
                    JavaScript run in the main frame of every page before its own scripts, from the next load \
                    (navigate reload; a single-page app's route change is no load): performance observers, timing \
                    marks, API stubs.
                    """],
                "textReplace": ["type": ["array", "null"], "items": ["type": "array", "items": ["type": "string"]], "description": """
                    [[pattern, replacement], ...] kept applied as the page renders, for anonymized captures: text, field \
                    values, placeholder, title, alt and aria-label, shadow DOM, every frame and the tab title, now and at each \
                    load. A pattern is literal text matched as whole words in any case, or /a regex/flags ($1 in the \
                    replacement). Text split across elements, canvas and images are not reached. null puts the page's text back.
                    """],
                "textReplaceGuard": ["type": ["boolean", "array", "null"], "items": ["type": "string"], "description": """
                    true, or more patterns that must not show, like the first name alone: computer screenshot and zoom fail \
                    while a textReplace or guard pattern matches the rendered text, a name split by markup included, or a field.
                    """],
                "frozen": ["type": ["boolean", "null"], "description": """
                    true freezes the tab as Lilo freezes a user's tab left in the background (page suspended, told it \
                    is hidden, media paused). Your next call on the tab wakes it, as the user coming back to it.
                    """],
                "reset": AgentTools.prop("boolean", "Undo every emulation of the tab."),
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["tabId"]),
        AgentTools.tool("performance", """
            Measure a tab. Your tabs render and run timers at full rate, even unseen. metrics: load and paint \
            timings, LCP, CLS and long tasks (null where WebKit lacks the API: stop lists long tasks), DOM size, \
            visibility, and the tab's process memory with its breakdown (JavaScript, JIT, images, layers, page). \
            start, then act, then stop: a timeline profile (JavaScript samples, layout, style, paint, CPU, memory) \
            saved as a JSON file, with a summary: functions with their callers, inclusive time, time by file and by \
            origin (first party, third party, extension), long tasks (50 ms or more) with the functions running \
            in them, and the sections between console.timeStamp marks. summary: the last profile again over \
            fromMs to toMs, or with focus. A cross-site navigation moves the page to a new process: the profile \
            follows it, but the samples taken before are lost, so start on the loaded page or right before \
            navigating. Records' totalMs is the time covered by records of that type. heap_snapshot: collects \
            garbage, then saves the JavaScript heap as a file, with the biggest classes, the growth since the \
            previous snapshot, the DOM trees detached from every document and what keeps them, and with \
            className what retains that class. gc: collect garbage. Extensions of a user's profile run in its \
            pages: the Agents profile has none.
            """, [
                "action": ["type": "string", "enum": ["metrics", "start", "stop", "summary", "heap_snapshot", "gc"]],
                "fromMs": AgentTools.prop("number", "stop, summary: only what happened from this many ms after the start."),
                "toMs": AgentTools.prop("number", "stop, summary: only what happened until this many ms after the start."),
                "focus": AgentTools.prop("string", "stop, summary: the call paths leading to functions whose name contains this, like appendChild."),
                "screenshots": AgentTools.prop("boolean", "start: also record a screenshot each frame, which costs the page time (off by default)."),
                "className": AgentTools.prop("string", "heap_snapshot: list what retains objects of this class, and a path to one from a root."),
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["action", "tabId"])
    ]

    static func call(
        _ name: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async throws -> [AgentContent]? {
        switch name {
        case "devtools_command":
            let inspector = try await inspector(arguments, session: session, control: control)
            guard let method = arguments["method"] as? String, !method.isEmpty else {
                return [.text(try await inspector.script("commands") as? String ?? "")]
            }
            let result = try await inspector.command(method, arguments["params"] as? [String: Any] ?? [:])
            return [.text(AgentTools.json(result))]
        case "devtools_events":
            let inspector = try await inspector(arguments, session: session, control: control)
            var options: [String: Any] = ["prefix": arguments["prefix"] as? String ?? "", "clear": arguments["clear"] as? Bool ?? false]
            options["limit"] = arguments["limit"] as? NSNumber
            let events = try await inspector.script("events", options) as? String ?? ""
            return [.text(events.isEmpty ? "No events" : events)]
        case "network_mock":
            let inspector = try await inspector(arguments, session: session, control: control)
            switch arguments["action"] as? String {
            case "add":
                var rule = arguments.filter {
                    ["urlPattern", "methods", "bodyPattern", "bodyJson", "stage", "response", "error", "modify", "delayMs"].contains($0.key)
                }
                if var response = rule["response"] as? [String: Any], let path = response["path"] as? String {
                    let template = (path as NSString).expandingTildeInPath
                    guard template.hasPrefix("/") else { throw AgentToolError("path must be absolute: \(path)") }
                    // With groups, what may be served is the folder holding the path's fixed part.
                    let folder = template.firstIndex(of: "$").map { String(template[..<(template[..<$0].lastIndex(of: "/") ?? template.startIndex)]) }
                    let root = URL(fileURLWithPath: folder ?? template).standardizedFileURL.path
                    guard FileManager.default.fileExists(atPath: root) else { throw AgentToolError("No file at \(root)") }
                    let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
                    _ = try await control.approveUpload(URL(fileURLWithPath: root), engine: engine, session: session)
                    inspector.serve(folder == nil ? root : root + "/")
                    response["path"] = template
                    rule["response"] = response
                }
                let id = try await inspector.script("addRule", rule)
                var reply = "Added rule \((id as? NSNumber)?.intValue ?? 0)"
                if let methods = rule["methods"] as? [String], !methods.contains(where: { ["GET", "HEAD"].contains($0.uppercased()) }),
                   let pattern = rule["urlPattern"] as? String, pattern.isEmpty || [".*", "^.*", ".+", "^"].contains(pattern) {
                    reply += "\nWarning: WebKit intercepts every URL this pattern matches, GETs included: the page's preloads will fire error. Narrow urlPattern to the API."
                }
                return [.text(reply)]
            case "remove":
                _ = try await inspector.script("removeRule", ["id": arguments["id"] ?? 0])
                return [.text("Removed rule \(arguments["id"] ?? "")")]
            case "list":
                return [.text(AgentTools.json(try await inspector.script("rules") ?? []))]
            case "clear":
                _ = try await inspector.script("clearRules")
                return [.text("Removed every rule")]
            default:
                throw AgentToolError("action must be add, remove, list or clear")
            }
        case "network_response":
            let inspector = try await inspector(arguments, session: session, control: control)
            var options: [String: Any] = ["url": arguments["url"] as? String ?? "", "all": arguments["all"] as? Bool ?? false]
            let har = arguments["har"] as? Bool ?? false
            options["har"] = har
            options["method"] = arguments["method"] as? String
            options["responseBody"] = arguments["responseBody"] as? Bool ?? true
            if let id = arguments["requestId"], !(id is NSNull) { options["requestId"] = "\(id)" }
            options["maxChars"] = arguments["max_chars"] as? NSNumber
            let result = try await inspector.script("response", options) as? String ?? ""
            guard har else { return [.text(result)] }
            let url = try await Task.detached { try save(Data(result.utf8), prefix: "network", extension: "har") }.value
            return [.text("Saved the requests to \(url.path)")]
        case "cookies":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            let (space, _) = try control.agentSpace(for: session)
            let tabs = (session.folderId.map { control.tabs(inFolder: $0, spaceId: space.id) } ?? []) + control.isolatedTabs(of: session)
            var hosts = Set(tabs.compactMap { $0.url?.host() })
            if let host = engine.currentURL?.host() { hosts.insert(host) }
            return [.text(try await cookies(arguments, store: engine.wkWebView.configuration.websiteDataStore.httpCookieStore, hosts: hosts))]
        case "emulate":
            let (tab, engine) = try control.agentTab(arguments["tabId"], session: session)
            let inspector = try await control.inspector(for: tab.id, engine: engine)
            let fields = [
                "userAgent", "colorScheme", "reducedMotion", "contrast", "media", "javascript", "images", "cache", "extraHeaders", "initScript",
                "textReplace", "textReplaceGuard"
            ]
            var changes = arguments.filter { fields.contains($0.key) }
            var scale = (arguments["deviceScaleFactor"] as? NSNumber).map { CGFloat($0.doubleValue) }
            if arguments.keys.contains("deviceScaleFactor"), scale == nil { scale = 0 }
            if arguments["reset"] as? Bool == true {
                changes = Dictionary(uniqueKeysWithValues: fields.map { ($0, NSNull() as Any) })
                scale = 0
            }
            if let scale, !(0...10).contains(scale) { throw AgentToolError("deviceScaleFactor goes from 0 (the screen's) to 10") }
            // The page fields go first: they are all validated before any applies, the scale is set only after.
            var state = try await inspector.script("emulate", changes) as? [String: Any] ?? [:]
            inspector.guardsText = state["textReplaceGuard"] as? Bool ?? (state["textReplaceGuard"] is [Any])
            if let scale {
                guard engine.isAgentControlled else { throw AgentToolError("The tab left your tab group") }
                inspector.deviceScaleFactor = scale
            }
            if inspector.deviceScaleFactor != 0 { state["deviceScaleFactor"] = Double(inspector.deviceScaleFactor) }
            if arguments["frozen"] as? Bool == true {
                engine.freeze()
                state["frozen"] = engine.isFrozen
            }
            return [.text(state.isEmpty ? "No emulation" : AgentTools.json(state))]
        case "performance":
            let (tab, engine) = try control.agentTab(arguments["tabId"], session: session)
            let action = arguments["action"] as? String
            if action != "summary" { try await ensureResponsive(engine) }
            switch action {
            case "metrics":
                var result = try await metrics(engine)
                let memory = try? await control.inspector(for: tab.id, engine: engine).script("memory") as? [String: Any]
                if let memory, !memory.isEmpty { result["memoryMB"] = memory }
                return [.text(AgentTools.json(result))]
            case "start":
                let screenshots = arguments["screenshots"] as? Bool ?? false
                _ = try await control.inspector(for: tab.id, engine: engine).script("startProfile", ["screenshots": screenshots])
                return [.text("Profiling: act on the page, then call performance stop")]
            case "stop", "summary":
                var options = arguments.filter { ["fromMs", "toMs", "focus"].contains($0.key) }
                options["pageURL"] = engine.currentURL?.absoluteString ?? ""
                let inspector = try await control.inspector(for: tab.id, engine: engine)
                guard action == "stop" else {
                    return [.text(AgentTools.json(try await inspector.script("summarizeProfile", options) ?? [:]))]
                }
                let hidden = try? await engine.wkWebView.evaluateJavaScript("document.visibilityState") as? String == "hidden"
                var summary = try await inspector.script("stopProfile", options) as? [String: Any] ?? [:]
                if hidden == true { summary["warning"] = "The page was hidden: rendering and timers ran throttled, timings are off" }
                let url = try await saveRaw(of: inspector, prefix: "profile")
                return [.text("Saved the profile to \(url.path)\n" + AgentTools.json(summary))]
            case "heap_snapshot":
                let inspector = try await control.inspector(for: tab.id, engine: engine)
                let summary = try await inspector.script("heapSnapshot", ["className": arguments["className"] as? String ?? ""]) ?? [:]
                let url = try await saveRaw(of: inspector, prefix: "heap")
                return [.text("Saved the heap snapshot to \(url.path)\n" + AgentTools.json(summary))]
            case "gc":
                _ = try await control.inspector(for: tab.id, engine: engine).script("collectGarbage")
                return [.text("Collected garbage")]
            default:
                throw AgentToolError("action must be metrics, start, stop, summary, heap_snapshot or gc")
            }
        default:
            return nil
        }
    }

    private static let metricsScript = """
        // WebKit ignores a type it lacks instead of failing: it would read as none happened.
        const supported = PerformanceObserver.supportedEntryTypes ?? []
        const observed = type => !supported.includes(type) ? Promise.resolve(null) : new Promise(resolve => {
          try {
            const entries = []
            const observer = new PerformanceObserver(list => entries.push(...list.getEntries()))
            observer.observe({ type, buffered: true })
            setTimeout(() => { observer.disconnect(); resolve(entries) }, 50)
          } catch { resolve(null) }
        })
        const types = ['largest-contentful-paint', 'layout-shift', 'longtask']
        const [lcp, shifts, longTasks] = await Promise.all(types.map(observed))
        const navigation = performance.getEntriesByType('navigation')[0]
        return {
          navigation: navigation ? {
            responseStartMs: Math.round(navigation.responseStart), domContentLoadedMs: Math.round(navigation.domContentLoadedEventEnd),
            loadMs: Math.round(navigation.loadEventEnd), transferBytes: navigation.transferSize
          } : null,
          paintMs: Object.fromEntries(performance.getEntriesByType('paint').map(e => [e.name, Math.round(e.startTime)])),
          largestContentfulPaintMs: lcp?.length ? Math.round(lcp.at(-1).startTime) : null,
          cumulativeLayoutShift: shifts ? Math.round(shifts.filter(e => !e.hadRecentInput).reduce((sum, e) => sum + e.value, 0) * 1000) / 1000 : null,
          longTasks: longTasks ? { count: longTasks.length, totalMs: Math.round(longTasks.reduce((sum, e) => sum + e.duration, 0)) } : null,
          // A bare null reads as a failed measure: the reply says which entries WebKit never reports.
          entryTypesWebKitLacks: types.filter(type => !supported.includes(type)),
          domNodes: document.getElementsByTagName('*').length,
          visibility: document.visibilityState,
          resources: performance.getEntriesByType('resource').length,
          // The browser keeps 250 by default: a full buffer undercounts.
          resourceTimingFull: performance.getEntriesByType('resource').length >= 250,
          memoryCovers: 'the whole web content process, which other tabs of the same site can share'
        }
        """

    /// What the page knows of its own speed, plus the memory of the tab's web process.
    private static func metrics(_ engine: WKWebViewTab) async throws -> [String: Any] {
        let webView = engine.wkWebView
        var result = try await webView.callAsyncJavaScript(metricsScript, arguments: [:], contentWorld: AgentInput.world) as? [String: Any] ?? [:]
        let pidSelector = NSSelectorFromString("_webProcessIdentifier")
        if webView.responds(to: pidSelector), let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if status == 0 { result["memoryFootprintMB"] = (Double(usage.ri_phys_footprint) / 1_048_576 * 10).rounded() / 10 }
        }
        return result
    }

    /// The heap and timeline commands wait for the page's thread: a script holding it would hang them unseen.
    private static func ensureResponsive(_ engine: WKWebViewTab) async throws {
        let answered = await withCheckedContinuation { continuation in
            var done = false
            let finish = { (value: Bool) in
                guard !done else { return }
                done = true
                continuation.resume(returning: value)
            }
            engine.wkWebView.evaluateJavaScript("0") { _, _ in finish(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
        }
        guard answered else {
            throw AgentToolError("The page's thread is busy: a script has held it for 3 s or more. Wait for it, or reload the tab")
        }
    }

    /// The JSON of the profile or snapshot the inspector just took, fetched in pieces: whole, it can be too
    /// big to come back from the frontend.
    private static func saveRaw(of inspector: AgentInspector, prefix: String) async throws -> URL {
        var data = Data()
        var from = 0
        while true {
            let piece = try await inspector.script("rawChunk", ["from": from, "length": 8_000_000]) as? [String: Any] ?? [:]
            let text = piece["text"] as? String ?? ""
            guard !text.isEmpty, let next = (piece["next"] as? NSNumber)?.intValue else { break }
            data.append(contentsOf: text.utf8)
            from = next
        }
        return try await Task.detached { [data] in try save(data, prefix: prefix) }.value
    }

    nonisolated private static func save(_ contents: Data, prefix: String, extension: String = "json") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lilo-agent")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The agent reads each file as soon as it is named: a day later it is only disk.
        let stale = Date().addingTimeInterval(-86_400)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture) < stale {
            try? FileManager.default.removeItem(at: file)
        }
        let url = folder.appending(path: "\(prefix)-\(Int(Date().timeIntervalSince1970 * 1000)).\(`extension`)")
        try contents.write(to: url)
        return url
    }

    /// `hosts`: the sites the agent's tabs show; get, delete and clear reach only the cookies sent to them.
    private static func cookies(_ arguments: [String: Any], store: WKHTTPCookieStore, hosts: Set<String>) async throws -> String {
        // A cookie's domain covers its subdomains; a leading dot changes nothing.
        let bare = { (domain: String) in domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }
        func covers(_ domain: String, _ host: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let domain = (arguments["domain"] as? String).map(bare)
        let reachable = { (cookie: HTTPCookie) in hosts.contains { covers(bare(cookie.domain), $0) } }
        switch arguments["action"] as? String {
        case "get":
            let host = (arguments["url"] as? String).flatMap { URL(string: $0)?.host() }
            let cookies = await store.allCookies().filter { cookie in
                guard reachable(cookie) else { return false }
                if let host, !covers(bare(cookie.domain), host) { return false }
                if let domain, !covers(domain, bare(cookie.domain)) { return false }
                return true
            }
            return AgentTools.json(cookies.map { cookie in
                [
                    "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
                    "expires": cookie.expiresDate.map { Int($0.timeIntervalSince1970) } ?? NSNull(),
                    "httpOnly": cookie.isHTTPOnly, "secure": cookie.isSecure, "sameSite": cookie.sameSitePolicy?.rawValue ?? NSNull()
                ] as [String: Any]
            })
        case "set":
            guard let fields = arguments["cookie"] as? [String: Any], let name = fields["name"] as? String,
                  let value = fields["value"] as? String, let cookieDomain = fields["domain"] as? String else {
                throw AgentToolError("cookie needs name, value and domain")
            }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: cookieDomain, .path: fields["path"] as? String ?? "/"]
            if let expires = fields["expires"] as? NSNumber { properties[.expires] = Date(timeIntervalSince1970: expires.doubleValue) }
            if fields["secure"] as? Bool == true { properties[.secure] = "TRUE" }
            if fields["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            switch (fields["sameSite"] as? String)?.lowercased() {
            case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
            case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
            default: break
            }
            guard let cookie = HTTPCookie(properties: properties) else { throw AgentToolError("Invalid cookie") }
            await store.setCookie(cookie)
            return "Set cookie \(name) for \(cookieDomain)"
        case "delete", "clear":
            guard let domain else { throw AgentToolError("\(arguments["action"] as? String ?? "") needs a domain") }
            // "com" would take every .com cookie of the profile.
            guard domain.contains(".") || domain == "localhost" else { throw AgentToolError("\(domain) is not a site's domain") }
            let name = arguments["name"] as? String
            if arguments["action"] as? String == "delete", name == nil { throw AgentToolError("delete needs a name") }
            let doomed = await store.allCookies().filter { cookie in
                reachable(cookie) && covers(domain, bare(cookie.domain)) && (name == nil || cookie.name == name)
            }
            for cookie in doomed { await store.deleteCookie(cookie) }
            return "Deleted \(doomed.count) cookies"
        default:
            throw AgentToolError("action must be get, set, delete or clear")
        }
    }

    /// Throws while emulate's textReplaceGuard finds a textReplace pattern still on the tab's page.
    static func refuseTextLeaks(tabId: UUID, control: AgentControl) async throws {
        guard let inspector = control.inspectors[tabId], inspector.guardsText else { return }
        if let leak = try await inspector.script("textLeaks") as? String { throw AgentToolError(leak) }
    }

    private static func inspector(_ arguments: [String: Any], session: AgentSession, control: AgentControl) async throws -> AgentInspector {
        let (tab, engine) = try control.agentTab(arguments["tabId"], session: session)
        return try await control.inspector(for: tab.id, engine: engine)
    }
}
