import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Input, screenshots, capture and the other tools beyond tabs and page reading.
@MainActor
enum AgentInteractionTools {
    static let definitions: [[String: Any]] = [
        AgentTools.tool("computer", """
            Mouse and keyboard in a tab, plus screenshots. Coordinates are pixels of a plain screenshot, the viewport \
            at one pixel per point, origin top left; a fullPage, fullResolution or element screenshot keeps that frame \
            and says how its own pixels map to it. Click on an element's center: take a screenshot first to find it, \
            or pass `ref` instead. Lilo's agent cursor never shows in screenshots.
            Actions: left_click, right_click, double_click, triple_click, type, insert_text, key, screenshot, wait, \
            scroll, left_click_drag, zoom, scroll_to, hover. insert_text puts text at the caret in one go, as the text \
            system does, with no key presses and the clipboard left alone: the way for long or multi-line text in a \
            rich editor; type sends real keys, for pages that listen to them. Both need a focused text field: click it \
            first. key presses keys wherever the focus is. A click or hover says what it landed on.
            A click or Enter on a control that sends, pays, buys, orders, deletes, transfers, publishes or signs up \
            first waits up to 45 s for the user's approval in Lilo; refused or unanswered, it fails with [needs_user]: \
            ask the user to do it or allow it. A click or key returns once the requests it started end, up to 10 s, and \
            names those still running: leaving the page then may cancel them.
            """, [
                "action": ["type": "string", "enum": ["left_click", "right_click", "double_click", "triple_click", "type", "insert_text", "key",
                                                      "screenshot", "wait", "scroll", "left_click_drag", "zoom", "scroll_to", "hover"]],
                "coordinate": ["type": "array", "items": ["type": "number"], "description": "(x, y) for clicks, scroll, hover, and the end of a drag."],
                "ref": AgentTools.prop("string", "An element ref from read_page or find, instead of coordinate; for screenshot, the element to capture."),
                "selector": AgentTools.prop("string", "screenshot: a CSS selector of the element to capture, instead of ref."),
                "margin": AgentTools.prop("number", "screenshot of an element: CSS pixels kept around it, 0 by default."),
                "fullPage": AgentTools.prop("boolean", "screenshot: the whole page, lazy content loaded, without resizing the viewport."),
                "fullResolution": AgentTools.prop("boolean", "screenshot: at the page's device pixel ratio instead of one pixel per point."),
                "savePath": AgentTools.prop("string", "screenshot: an absolute .png path to write it to, folders created; the reply gives the path, not the image."),
                "text": AgentTools.prop("string", "The text to type or insert, or for key the keys: space separated, modifiers joined by + (cmd+a, Return)."),
                "modifiers": AgentTools.prop("string", "Modifier keys held during a click, joined by + (cmd, shift, alt, ctrl)."),
                "scroll_direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "scroll_amount": AgentTools.prop("number", "Wheel ticks, 3 by default."),
                "start_coordinate": ["type": "array", "items": ["type": "number"], "description": "(x, y) where a drag starts."],
                "region": ["type": "array", "items": ["type": "number"], "description": "(x0, y0, x1, y1) to zoom on."],
                "duration": AgentTools.prop("number", "Seconds to wait, at most 10."),
                "repeat": AgentTools.prop("number", "How many times to press the keys of a key action."),
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["action", "tabId"]),
        AgentTools.tool("resize_window", """
            Set the size of a tab's viewport, to test a layout at another width (1280x800 until set). Lilo's own window \
            does not change. The size stays through navigations until the tab leaves your group.
            """, [
                "width": AgentTools.prop("number", "Width in pixels."), "height": AgentTools.prop("number", "Height in pixels."),
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["width", "height", "tabId"]),
        AgentTools.tool("read_console_messages", "Console output of the tab's current page: logs, warnings, errors and uncaught exceptions.", [
            "tabId": AgentTools.prop("number", "The tab."),
            "onlyErrors": AgentTools.prop("boolean", "Only errors."),
            "pattern": AgentTools.prop("string", "Only messages containing this text."),
            "limit": AgentTools.prop("number", "Most recent messages to return, 50 by default, at most 200.")
        ], required: ["tabId"]),
        AgentTools.tool("read_network_requests", """
            Network requests of the tab, newest last: id, method, status, URL, then type, size and duration. Once a \
            devtools tool ran on the tab, they are the inspector's, under a line for each page load: the same ids, sizes \
            and timings as network_response, and requestId gives one in full, body included. Before, the size is the \
            Content-Length header.
            """, [
            "tabId": AgentTools.prop("number", "The tab."),
            "urlPattern": AgentTools.prop("string", "Only requests whose URL contains this text, as is: not a regex, unlike network_mock's."),
            "exclude": [
                "type": "array", "items": ["type": "string"],
                "description": "Leave out requests whose URL contains any of these texts, like [\"/node_modules/\", \"/@vite/\", \"/src/\"] for a dev server's modules."
            ],
            "requestId": AgentTools.prop("string", "One request in full, its id as a string: \"0.16620\"."),
            "limit": AgentTools.prop("number", "Most recent requests to return, 50 by default.")
        ], required: ["tabId"]),
        AgentTools.tool("file_upload", "Choose files for a file input, without a file panel. The user allows each file first.", [
            "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths of the files."],
            "ref": AgentTools.prop("string", "The file input's ref."),
            "tabId": AgentTools.prop("number", "The tab.")
        ], required: ["paths", "ref", "tabId"]),
        AgentTools.tool("upload_image", "Drop an image on an element or set it on a file input: a screenshot by imageId, or a file by path.", [
            "imageId": AgentTools.prop("string", "The id of a screenshot taken with computer."),
            "path": AgentTools.prop("string", "An absolute path to an image file, which the user allows first."),
            "ref": AgentTools.prop("string", "The target element's ref."),
            "coordinate": ["type": "array", "items": ["type": "number"], "description": "(x, y) of the target instead of ref."],
            "filename": AgentTools.prop("string", "The file name the page sees."),
            "tabId": AgentTools.prop("number", "The tab.")
        ], required: ["tabId"]),
        AgentTools.tool("gif_creator", """
            Record the actions in a tab as an animated GIF: start_recording, then act, then stop_recording and export, \
            which saves it to the Downloads folder. clear drops the frames.
            """, [
                "action": ["type": "string", "enum": ["start_recording", "stop_recording", "export", "clear"]],
                "filename": AgentTools.prop("string", "File name for export."),
                "tabId": AgentTools.prop("number", "The tab.")
            ], required: ["action", "tabId"]),
        AgentTools.tool("browser_batch", "Run several tool calls in order in one round trip, stopping at the first error.", [
            "actions": ["type": "array", "description": "Each item is {name, input}: a tool name and its arguments.",
                        "items": ["type": "object", "properties": ["name": ["type": "string"], "input": ["type": "object"]], "required": ["name", "input"]]]
        ], required: ["actions"]),
        AgentTools.tool("run", """
            Run a JavaScript program that calls the other tools itself: loops and branches over many steps in one \
            round trip. `await tool(name, input)` returns that tool's text (JSON.parse it where the tool answers JSON) \
            and throws its error. The program runs in a blank page of its own, apart from your tabs, so it outlives \
            their navigations: reach a page with tool("javascript_tool", ...), tool("get_page_text", ...) and the like. \
            At most 200 tool calls, and 55 s unless timeout says otherwise. Returns the program's return value, as \
            JSON for an object, and how many tools it called; images are left out. The tools it calls ask the user as \
            they would alone; its own code is not asked about, so never use it to do what the user denied.
            """, [
                "code": AgentTools.prop("string", """
                    The body of an async function: await and return work. For example: for (const u of urls) \
                    { await tool('navigate', {tabId: 1, url: u}); out.push(await tool('get_page_text', {tabId: 1})) } return out
                    """),
                "timeout": AgentTools.prop("number", "Seconds before the run is stopped, 55 by default, up to 600. Past 60 s your MCP client may stop waiting first, unless it takes progress notifications.")
            ], required: ["code"]),
        AgentTools.tool("list_profiles", """
            Lilo's profiles, each with its own cookies and sign-ins. Your tabs run in the one marked current: by default \
            the ephemeral Agents profile, signed in nowhere and wiped after the last agent in it. usedByUser marks the \
            profile the user works in now, where their sign-ins are.
            """, [:]),
        AgentTools.tool("switch_profile", """
            Move your tabs to another profile, to act with its sign-ins: they reload there. Other agents stay in \
            their own profile. The user allows each profile once.
            """, ["profile": AgentTools.prop("string", "The profile's name or id, from list_profiles.")], required: ["profile"]),
        AgentTools.tool("reset_profile", """
            Start over signed in nowhere: wipes the ephemeral Agents profile (cookies, storage, cache, history) and reloads \
            your tabs. Only that profile, never one of the user's; refused while another agent has tabs in it, unless wait \
            lets it finish first.
            """, ["wait": AgentTools.prop("number", "Seconds to wait for other agents to close their tabs, up to 600 (default 0).")]),
        AgentTools.tool("list_connected_browsers", "Lists the browsers this server can drive: the running Lilo.", [:]),
        AgentTools.tool("select_browser", "Select the browser to drive. Lilo is the only one.", ["deviceId": AgentTools.prop("string", "The browser id.")]),
        AgentTools.tool("switch_browser", "Connect to a browser. Lilo is already connected.", [:])
    ]

    static func call(
        _ name: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async throws -> [AgentContent]? {
        switch name {
        case "computer":
            return try await computer(arguments, session: session, control: control)
        case "resize_window":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            guard let width = number(arguments["width"]), let height = number(arguments["height"]),
                  (100...16384).contains(width), (100...16384).contains(height) else {
                throw AgentToolError("width and height go from 100 to 16384")
            }
            engine.agentViewport = NSSize(width: width, height: height)
            engine.fitView(in: engine.view.superview?.bounds ?? engine.view.frame)
            (engine.view.superview as? ContentContainerView)?.updateStage(under: engine.view, fixedSize: true)
            return [.text("Resized the viewport to \(Int(width))x\(Int(height)), kept until the tab leaves your group" + zoomNote(engine))]
        case "read_console_messages":
            let (tab, _) = try control.agentTab(arguments["tabId"], session: session)
            var messages = await control.captures[tab.id]?.consoleMessages() ?? []
            if arguments["onlyErrors"] as? Bool == true { messages = messages.filter { $0["level"] as? String == "error" } }
            if let pattern = arguments["pattern"] as? String, !pattern.isEmpty {
                messages = messages.filter { ($0["text"] as? String)?.localizedCaseInsensitiveContains(pattern) == true }
            }
            let limit = Int(min(max(number(arguments["limit"]) ?? 50, 0), 200))
            let lines = messages.suffix(limit).map { "[\($0["level"] as? String ?? "log")] \($0["text"] as? String ?? "")" }
            return [.text(lines.isEmpty ? "No console messages" : lines.joined(separator: "\n"))]
        case "read_network_requests":
            let (tab, _) = try control.agentTab(arguments["tabId"], session: session)
            guard let inspector = control.inspectors[tab.id], inspector.isCurrent else {
                return [.text(await networkReport(arguments, capture: control.captures[tab.id]))]
            }
            if let id = arguments["requestId"], !(id is NSNull) {
                return [.text(try await inspector.script("response", ["requestId": "\(id)"]) as? String ?? "")]
            }
            var options: [String: Any] = ["urlPattern": arguments["urlPattern"] as? String ?? "", "exclude": arguments["exclude"] as? [String] ?? []]
            options["limit"] = arguments["limit"] as? NSNumber
            let list = try await inspector.script("list", options) as? String ?? ""
            return [.text(list.isEmpty ? "No requests captured" : list)]
        case "file_upload":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            var urls = (arguments["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { throw AgentToolError("paths is required") }
            if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                throw AgentToolError("No file at \(missing.path)")
            }
            for index in urls.indices { urls[index] = try await control.approveUpload(urls[index], engine: engine, session: session) }
            engine.pendingAgentUploads = urls
            // The input itself is clicked, not the point it sits at: sites hide it under their own button.
            if let ref = arguments["ref"] as? String {
                _ = try await AgentTools.page(engine, "act", ["ref": ref, "action": "left_click"], in: try await AgentTools.frame(holding: ref, in: engine))
            } else {
                await AgentInput.click(engine.wkWebView, at: try await point(of: arguments, engine: engine))
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while engine.pendingAgentUploads != nil, !Task.isCancelled, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            guard engine.pendingAgentUploads == nil else {
                engine.pendingAgentUploads = nil
                throw AgentToolError("The element opened no file picker: pass the ref of an <input type=file>")
            }
            return [.text("Uploaded \(urls.map(\.lastPathComponent).joined(separator: ", "))")]
        case "upload_image":
            let (_, engine) = try control.agentTab(arguments["tabId"], session: session)
            let data: Data
            if let id = arguments["imageId"] as? String {
                guard let shot = control.screenshots.first(where: { $0.id == id }) else { throw AgentToolError("No screenshot \(id)") }
                data = shot.png
            } else if let path = arguments["path"] as? String, FileManager.default.fileExists(atPath: path) {
                let file = try await control.approveUpload(URL(fileURLWithPath: path), engine: engine, session: session)
                guard let contents = FileManager.default.contents(atPath: file.path) else { throw AgentToolError("Cannot read \(path)") }
                data = contents
            } else {
                throw AgentToolError("Pass imageId or a readable path")
            }
            let filename = arguments["filename"] as? String ?? (arguments["path"] as? String).map { ($0 as NSString).lastPathComponent } ?? "image.png"
            let type = UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType ?? "image/png"
            var target: [String: Any] = ["name": filename, "type": type, "base64": data.base64EncodedString()]
            var frame: WKFrameInfo?
            if let ref = arguments["ref"] as? String {
                target["ref"] = ref
                frame = try await AgentTools.frame(holding: ref, in: engine)
            } else {
                let point = try await point(of: arguments, engine: engine)
                target["x"] = point.x / engine.pageZoom
                target["y"] = point.y / engine.pageZoom
            }
            return [.text(try await AgentTools.page(engine, "dropFile", target, in: frame) as? String ?? "")]
        case "gif_creator":
            let (tab, engine) = try control.agentTab(arguments["tabId"], session: session)
            switch arguments["action"] as? String {
            case "start_recording":
                control.recordings[tab.id] = []
                control.recordingTabs.insert(tab.id)
                await recordFrame(engine, tabId: tab.id, control: control)
                return [.text("Recording started")]
            case "stop_recording":
                control.recordingTabs.remove(tab.id)
                return [.text("Recording stopped with \(control.recordings[tab.id]?.count ?? 0) frames")]
            case "clear":
                control.recordings[tab.id] = nil
                control.recordingTabs.remove(tab.id)
                return [.text("Frames cleared")]
            case "export":
                guard let frames = control.recordings[tab.id], !frames.isEmpty else { throw AgentToolError("Nothing recorded: start_recording first") }
                let filename = arguments["filename"] as? String
                let url = try await Task.detached { try exportGIF(frames, filename: filename) }.value
                return [.text("Saved \(frames.count) frames to \(url.path)")]
            default:
                throw AgentToolError("action must be start_recording, stop_recording, export or clear")
            }
        case "browser_batch":
            var content: [AgentContent] = []
            for (index, action) in (arguments["actions"] as? [[String: Any]] ?? []).enumerated() {
                let tool = action["name"] as? String ?? ""
                guard tool != "browser_batch" else { throw AgentToolError("browser_batch cannot be nested") }
                try Task.checkCancellation()
                do {
                    content += try await AgentTools.call(tool, arguments: action["input"] as? [String: Any] ?? [:], session: session, control: control)
                } catch {
                    let done = content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
                    throw AgentToolError("\(done)\nAction \(index + 1) (\(tool)) failed: \(error.localizedDescription)", code: (error as? AgentToolError)?.code)
                }
            }
            return content
        case "run":
            return [.text(try await run(arguments["code"] as? String ?? "", session: session, control: control))]
        case "list_profiles":
            return [.text(AgentTools.json(try control.profileList(for: session)))]
        case "reset_profile":
            return [.text(try await control.resetProfile(for: session, wait: arguments["wait"]))]
        case "switch_profile":
            return [.text(try await control.switchProfile(arguments["profile"] as? String ?? "", for: session))]
        case "list_connected_browsers":
            return [.text(AgentTools.json([["deviceId": "lilo", "name": "Lilo", "isCurrent": true]]))]
        case "select_browser", "switch_browser":
            return [.text("Connected to Lilo")]
        default:
            return nil
        }
    }

    /// How long a click or key waits for the requests it started to end.
    static var requestWait = Duration.seconds(10)

    private static func computer(_ arguments: [String: Any], session: AgentSession, control: AgentControl) async throws -> [AgentContent] {
        let (tab, engine) = try control.agentTab(arguments["tabId"], session: session)
        let webView = engine.wkWebView
        let action = arguments["action"] as? String ?? ""
        var modifiers: NSEvent.ModifierFlags = []
        if let names = arguments["modifiers"] as? String, !names.isEmpty {
            guard let flags = AgentInput.modifierFlags(names.split(separator: "+")) else { throw AgentToolError("Unknown modifiers: \(names)") }
            modifiers = flags
        }
        var reply = ""
        var frame: WKFrameInfo?
        if let ref = arguments["ref"] as? String { frame = try await AgentTools.frame(holding: ref, in: engine) }
        let text = arguments["text"] as? String ?? ""
        if action == "type" || action == "insert_text" { try await requireTextField(engine) }
        let pressesEnter = action == "key" && text.split(separator: " ").contains { chord in
            chord.split(separator: "+").contains { ["return", "enter", "kp_enter"].contains($0.lowercased()) }
        } || action == "type" && text.contains(where: \.isNewline)
        var allowed = false
        if pressesEnter {
            allowed = try await control.approveConsequentialAction("enter", target: ["enter": true], frame: nil, engine: engine, session: session)
        } else if ["left_click", "double_click", "triple_click"].contains(action) {
            if let ref = arguments["ref"] as? String {
                allowed = try await control.approveConsequentialAction("click", target: ["ref": ref], frame: frame, engine: engine, session: session)
            } else if let point = coordinate(arguments["coordinate"]) {
                let css = ["x": point.x / engine.pageZoom, "y": point.y / engine.pageZoom]
                allowed = try await control.approveConsequentialAction("click", target: css, frame: nil, engine: engine, session: session)
            }
        }
        if action == "screenshot" || action == "zoom" { try await AgentDevTools.refuseTextLeaks(tabId: tab.id, control: control) }
        if pressesEnter { AgentCallSent.current?.write = true }
        let loadsBefore = control.captures[tab.id].map { Set($0.indexByLoad.keys) } ?? []
        switch action {
        case let refAction where frame != nil && ["left_click", "right_click", "double_click", "triple_click", "hover", "scroll_to"].contains(refAction):
            let parameters: [String: Any] = ["ref": arguments["ref"] ?? "", "action": action, "modifiers": arguments["modifiers"] ?? ""]
            reply = try await AgentTools.page(engine, "act", parameters, in: frame) as? String ?? ""
            if ["left_click", "double_click", "triple_click"].contains(action) { AgentCallSent.current?.write = true }
        case "left_click", "right_click", "double_click", "triple_click":
            let point = try await point(of: arguments, engine: engine)
            // Named before the click, which may leave the page: a click that missed its target shows at once.
            let hit = await hitAt(point, engine: engine)
            if action != "right_click" { AgentCallSent.current?.write = true }
            let clicks = ["double_click": 2, "triple_click": 3][action] ?? 1
            await AgentInput.click(webView, at: point, button: action == "right_click" ? .right : .left, clickCount: clicks, modifiers: modifiers)
            reply = "\(action == "right_click" ? "Right-clicked" : "Clicked") \(hit)at (\(Int(point.x)), \(Int(point.y)))"
        case "hover":
            let point = try await point(of: arguments, engine: engine)
            AgentInput.move(webView, to: point)
            reply = "Hovered \(await hitAt(point, engine: engine))at (\(Int(point.x)), \(Int(point.y)))"
        case "type":
            await AgentInput.type(webView, text: arguments["text"] as? String ?? "")
            reply = "Typed"
        case "insert_text":
            await AgentInput.insertText(webView, text: arguments["text"] as? String ?? "")
            reply = "Inserted"
        case "key":
            guard let keys = arguments["text"] as? String, !keys.isEmpty else { throw AgentToolError("text holds the keys to press") }
            for _ in 0..<Int(min(max(number(arguments["repeat"]) ?? 1, 1), 100)) { await AgentInput.key(webView, chord: keys) }
            reply = "Pressed \(keys)"
        case "wait":
            try await Task.sleep(for: .seconds(min(max(number(arguments["duration"]) ?? 1, 0), 10)))
            reply = "Waited"
        case "scroll":
            let point = (try? await point(of: arguments, engine: engine)) ?? CGPoint(x: webView.bounds.midX, y: webView.bounds.midY)
            reply = try await scroll(engine, at: point, direction: arguments["scroll_direction"] as? String ?? "down",
                                     ticks: min(max(number(arguments["scroll_amount"]) ?? 3, -100), 100))
        case "left_click_drag":
            guard let start = coordinate(arguments["start_coordinate"]) else { throw AgentToolError("start_coordinate is required") }
            let end = try await point(of: arguments, engine: engine)
            await AgentInput.drag(webView, from: start, to: end)
            reply = "Dragged from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y)))"
        case "scroll_to":
            _ = try await point(of: arguments, engine: engine)
            reply = "Scrolled \(arguments["ref"] as? String ?? "") into view"
        case "screenshot":
            return try await AgentScreenshot.take(arguments, engine: engine, tabId: tab.id, control: control)
        case "zoom":
            guard let region = arguments["region"] as? [NSNumber], region.count == 4 else { throw AgentToolError("region is (x0, y0, x1, y1)") }
            let values = region.map { CGFloat($0.doubleValue) }
            let rect = CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            guard rect.width > 0, rect.height > 0, let image = try? await webView.takeSnapshot(configuration: configuration),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let base64 = await Task.detached(operation: { png(cgImage)?.base64EncodedString() }).value else {
                throw AgentToolError("Could not capture that region")
            }
            return [.image(base64)]
        default:
            throw AgentToolError("Unknown action: \(action)")
        }
        // A click or Enter that leaves the page: the next read must find the new one, not the old.
        if ["left_click", "double_click", "triple_click", "key"].contains(action) {
            let start = ContinuousClock.now
            while !engine.isLoading, ContinuousClock.now - start < .milliseconds(100) { try? await Task.sleep(for: .milliseconds(20)) }
            if engine.isLoading { await AgentTools.waitForLoad(engine, capture: control.captures[tab.id]) }
            // A post or a payment sent by script: leaving the page before its request ends would cancel it.
            if let capture = control.captures[tab.id] {
                let running = { capture.indexByLoad.filter { !loadsBefore.contains($0.key) }.values.map { capture.requests[$0] } }
                while !running().isEmpty, ContinuousClock.now - start < requestWait { try? await Task.sleep(for: .milliseconds(50)) }
                let left = running()
                if !left.isEmpty {
                    let shown = left.prefix(3).map { "\($0.method) \($0.url.prefix(120))" }.joined(separator: ", ")
                    reply += ". \(left.count) request\(left.count == 1 ? "" : "s") it started still running (\(shown)): leaving or reloading the page now may cancel them"
                }
            }
        }
        if allowed { reply += " (the user allowed it in Lilo)" }
        if control.recordingTabs.contains(tab.id) { await recordFrame(engine, tabId: tab.id, control: control) }
        return [.text(reply)]
    }

    /// What the page shows at `point`, followed by a space, or nothing when the page cannot say.
    private static func hitAt(_ point: CGPoint, engine: WKWebViewTab) async -> String {
        let css = ["x": point.x / engine.pageZoom, "y": point.y / engine.pageZoom]
        return ((try? await AgentTools.page(engine, "hitAt", css)) as? String).map { $0 + " " } ?? ""
    }

    /// Keys typed with no text field focused reach the page, whose shortcuts they may set off.
    private static func requireTextField(_ engine: WKWebViewTab) async throws {
        let field = try await AgentTools.page(engine, "focusedField", [:])
        if field is String { return }
        if (field as? [String: Any])?["inFrame"] != nil {
            for (_, frame) in await AgentTools.subframes(of: engine) {
                if (try? await AgentTools.page(engine, "focusedField", [:], in: frame)) is String { return }
            }
        }
        throw AgentToolError("""
            No text field has focus: the text would go to the page, where letters can trigger its shortcuts. Click the \
            field first, then type; for keys meant for the page itself, use key.
            """)
    }

    /// The program runs in a blank web view of its own: a runaway loop stalls only that page's process, killed
    /// when the run is stopped.
    private static func run(_ code: String, session: AgentSession, control: AgentControl) async throws -> String {
        let tools = RunTools(session: session, control: control)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(tools, contentWorld: .page, name: "liloRun")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { configuration.userContentController.removeAllScriptMessageHandlers() }
        let script = """
            const tool = (name, input = {}) => window.webkit.messageHandlers.liloRun.postMessage({ name, input })
            const value = await (async () => { \(code)
            })()
            return value === undefined ? 'undefined' : typeof value === 'string' ? value : JSON.stringify(value, null, 2)
            """
        do {
            let value = try await withTaskCancellationHandler {
                try await webView.callAsyncJavaScript(script, contentWorld: .page)
            } onCancel: {
                Task { @MainActor in
                    tools.isStopped = true
                    let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
                    if webView.responds(to: kill) { webView.perform(kill) }
                }
            }
            return "\(value as? String ?? "undefined")\n(\(tools.calls) tool calls)"
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw AgentToolError("\(message)\n(\(tools.calls) tool calls)", code: tools.errorCode)
        }
    }

    /// Answers a run program's `tool(name, input)`.
    @MainActor
    private final class RunTools: NSObject, WKScriptMessageHandlerWithReply {
        static let limit = 200
        let session: AgentSession
        let control: AgentControl
        // The program's tools answer from WebKit callbacks, outside the run's task: they mark the run's call themselves.
        let sent = AgentCallSent.current
        var calls = 0
        var isStopped = false
        /// The code of the last tool error, kept for the run's own error when the program lets it through.
        var errorCode: String?

        init(session: AgentSession, control: AgentControl) {
            self.session = session
            self.control = control
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            let body = message.body as? [String: Any]
            let name = body?["name"] as? String ?? ""
            guard !isStopped else { return replyHandler(nil, "The run was stopped") }
            guard name != "run" else { return replyHandler(nil, "run cannot be nested") }
            calls += 1
            guard calls <= Self.limit else { return replyHandler(nil, "run is capped at \(Self.limit) tool calls: split the work into several runs") }
            nonisolated(unsafe) let input = body?["input"] as? [String: Any] ?? [:]
            Task {
                do {
                    let content = try await AgentCallSent.$current.withValue(sent) {
                        try await AgentTools.call(name, arguments: input, session: session, control: control)
                    }
                    replyHandler(content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n"), nil)
                } catch {
                    errorCode = (error as? AgentToolError)?.code ?? errorCode
                    replyHandler(nil, error.localizedDescription)
                }
            }
        }
    }

    /// `coordinate`, or the center of `ref` once scrolled into view, in web view points.
    private static func point(of arguments: [String: Any], engine: WKWebViewTab) async throws -> CGPoint {
        if let ref = arguments["ref"] as? String {
            guard try await AgentTools.frame(holding: ref, in: engine) == nil else {
                throw AgentToolError("\(ref) is inside a frame, whose coordinates are its own: pass a coordinate from a screenshot")
            }
            guard let box = try await AgentTools.page(engine, "rect", ["ref": ref]) as? [String: Any],
                  let x = number(box["x"]), let y = number(box["y"]) else { throw AgentToolError("No element \(ref)") }
            return CGPoint(x: x * engine.pageZoom, y: y * engine.pageZoom)
        }
        guard let point = coordinate(arguments["coordinate"]) else { throw AgentToolError("coordinate or ref is required") }
        return point
    }

    /// A wheel first, as a user scrolls; the page scrolls directly when the wheel moved nothing.
    private static func scroll(_ engine: WKWebViewTab, at point: CGPoint, direction: String, ticks: Double) async throws -> String {
        let distance = CGFloat(ticks * 100)
        let (dx, dy): (CGFloat, CGFloat) = switch direction {
        case "up": (0, -distance)
        case "left": (-distance, 0)
        case "right": (distance, 0)
        default: (0, distance)
        }
        let css = ["x": point.x / engine.pageZoom, "y": point.y / engine.pageZoom]
        let before = try await AgentTools.page(engine, "scrollState", css) as? String
        AgentInput.scroll(engine.wkWebView, at: point, deltaX: dx, deltaY: dy)
        try? await Task.sleep(for: .milliseconds(150))
        var after = try await AgentTools.page(engine, "scrollState", css) as? String
        if after == before {
            after = try await AgentTools.page(engine, "scrollBy", css.merging(["dx": dx / engine.pageZoom, "dy": dy / engine.pageZoom]) { $1 }) as? String
        }
        return "Scrolled \(direction), now at \(after ?? "")"
    }

    private static func networkReport(_ arguments: [String: Any], capture: AgentCapture?) async -> String {
        guard let capture else { return "No requests captured" }
        let pattern = arguments["urlPattern"] as? String ?? ""
        let excluded = arguments["exclude"] as? [String] ?? []
        let shown = { (url: String) in (pattern.isEmpty || url.contains(pattern)) && !excluded.contains { !$0.isEmpty && url.contains($0) } }
        let limit = Int(min(max(number(arguments["limit"]) ?? 50, 0), Double(AgentCapture.maxEntries)))
        guard capture.usesResourceLoadDelegate else {
            let entries = await capture.timedRequests().filter { shown($0["url"] as? String ?? "") }
            let lines = entries.suffix(limit).map { "\($0["status"].flatMap { $0 as? Int }.map(String.init) ?? "-") \($0["url"] as? String ?? "") (\($0["type"] as? String ?? ""), \($0["duration"] as? Int ?? 0) ms)" }
            return "Status codes may be missing: this WebKit reports resource timing only.\n" + lines.joined(separator: "\n")
        }
        let requests = capture.requests.filter { shown($0.url) }
        if let raw = arguments["requestId"], !(raw is NSNull) {
            guard let id = Int("\(raw)") else {
                return "No request \(raw): the inspector that listed it is gone, run any devtools tool on the tab and reload"
            }
            guard let request = requests.first(where: { $0.id == id }) else { return "No request \(id)" }
            return AgentTools.json([
                "requestId": request.id, "method": request.method, "url": request.url, "status": request.status ?? NSNull(),
                "mimeType": request.mimeType ?? NSNull(), "failed": request.failed, "contentLength": request.size ?? NSNull(),
                "durationMs": request.duration.map { Int($0 * 1000) } ?? NSNull()
            ]) + "\nHeaders, body and network timings: any devtools tool on the tab, then reload, then requestId again."
        }
        let lines = requests.suffix(limit).map { request in
            let status = request.failed ? "failed" : request.status.map(String.init) ?? "pending"
            let details = [request.mimeType, request.size.map { "\($0) B" }, request.duration.map { "\(Int($0 * 1000)) ms" }].compactMap { $0 }
            return "\(request.id) \(request.method) \(status) \(request.url)\(details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")"
        }
        return lines.isEmpty ? "No requests captured" : lines.joined(separator: "\n")
    }

    private static func recordFrame(_ engine: WKWebViewTab, tabId: UUID, control: AgentControl) async {
        let size = engine.wkWebView.bounds.size
        // One pixel per point, as screenshots: a Retina frame would be four times the memory for the same GIF.
        guard let image = await engine.takeSnapshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let frame = await Task.detached(operation: { scaled(image, width: Int(size.width), height: Int(size.height)) }).value else { return }
        // A recording that never stops keeps only the latest frames, 256 MB of them at most.
        let limit = max(1, min(300, 256 * 1024 * 1024 / max(frame.bytesPerRow * frame.height, 1)))
        let count = control.recordings[tabId, default: []].count
        if count >= limit { control.recordings[tabId]?.removeFirst(count - limit + 1) }
        control.recordings[tabId, default: []].append(frame)
    }

    nonisolated private static func exportGIF(_ frames: [CGImage], filename: String?) throws -> URL {
        let downloads = BuildIdentity.defaultDownloadsDirectory
        var name = filename ?? "lilo-recording-\(Int(Date().timeIntervalSince1970)).gif"
        if !name.lowercased().hasSuffix(".gif") { name += ".gif" }
        let url = downloads.appending(path: (name as NSString).lastPathComponent)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw AgentToolError("Could not write \(url.path)")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, delay) }
        guard CGImageDestinationFinalize(destination) else { throw AgentToolError("Could not write \(url.path)") }
        return url
    }

    /// A zoomed page lays out wider or narrower than its pixels: innerWidth is not the screenshot's width.
    static func zoomNote(_ engine: WKWebViewTab) -> String {
        let zoom = engine.pageZoom
        guard zoom != 1 else { return "" }
        let size = engine.view.bounds.size
        return " (page zoom \(Int((zoom * 100).rounded()))%: the page lays out at \(Int(size.width / zoom))x\(Int(size.height / zoom)) CSS px)"
    }

    nonisolated static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width >= 1, height >= 1 else { return nil }
        if image.width == width, image.height == height { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Nil past a million pixels either way, which no viewport has and which would trap converting to Int.
    private static func coordinate(_ value: Any?) -> CGPoint? {
        guard let pair = value as? [NSNumber], pair.count == 2, pair.allSatisfy({ abs($0.doubleValue) < 1_000_000 }) else { return nil }
        return CGPoint(x: pair[0].doubleValue, y: pair[1].doubleValue)
    }

    /// Finite only: a string like "nan" or "1e999" parses, and traps where it becomes an Int or a Duration.
    private static func number(_ value: Any?) -> Double? {
        ((value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)).flatMap { $0.isFinite ? $0 : nil }
    }
}
