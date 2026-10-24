import WebKit

/// `chrome.userScripts`, which WebKit lacks: registrations live in `ExtensionUserScripts`; `execute` runs scripts once. Also relays
/// `runtime.sendMessage`/`connect` from USER_SCRIPT worlds with `messaging` to `onUserScriptMessage`/`onUserScriptConnect`.
@MainActor
final class UserScriptsBridgeHandler: NSObject, GapHandler, WKScriptMessageHandlerWithReply {
    typealias UserScript = ExtensionStorage.UserScript
    typealias World = ExtensionStorage.UserScriptWorld

    static let messageHandlerName = "liloUserScript"
    /// A message nobody answers fails after this, as Chrome fails one without a receiver.
    static let replyTimeout: Duration = .seconds(300)

    let gapActions: Set<String> = [
        "userScripts.register",
        "userScripts.update",
        "userScripts.unregister",
        "userScripts.getScripts",
        "userScripts.configureWorld",
        "userScripts.getWorldConfigurations",
        "userScripts.resetWorldConfiguration",
        "userScripts.execute",
        "userScripts.reply",
        "userScripts.portPost",
        "userScripts.portDisconnect"
    ]
    private var pendingReplies: [String: (extensionId: String, reply: @MainActor @Sendable (Any?, String?) -> Void)] = [:]

    /// A user script's open `runtime.connect` port, by the id its page chose.
    private struct Port {
        let extensionId: String
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let world: WKContentWorld
    }
    private var ports: [String: Port] = [:]

    /// The profile registry of a web view running a user script, whose messages are not gap calls.
    private let registryResolver: (WKWebView) -> ProfileExtensionRegistry?

    init(registryResolver: @escaping (WKWebView) -> ProfileExtensionRegistry?) {
        self.registryResolver = registryResolver
    }

    func handle(_ call: GapCall) async -> Any? {
        let registry = call.registry, extensionId = call.extensionId
        guard let current = registry.userScripts.registrations(of: extensionId) else {
            return BridgeError("Extension not loaded")
        }
        guard registry.access.states[extensionId]?.allowsUserScripts == true else {
            return BridgeError("The userScripts API is unavailable: turn on \"Allow user scripts\" for this extension")
        }
        let (scripts, worlds) = current
        let ids = (call.payload["filter"] as? [String: Any])?["ids"] as? [String]

        switch call.action {
        case "userScripts.register":
            guard let added = Self.decode([UserScript].self, call.payload["scripts"]) else { return BridgeError("Invalid user scripts") }
            var all = scripts
            for var script in added {
                guard !all.contains(where: { $0.id == script.id }) else { return BridgeError("Duplicate script ID '\(script.id)'") }
                script.allFrames = script.allFrames ?? false
                script.runAt = script.runAt ?? "document_idle"
                script.world = script.world ?? "USER_SCRIPT"
                if let error = Self.validationError(script) { return BridgeError(error) }
                all.append(script)
            }
            await registry.userScripts.set(all, worlds: nil, for: extensionId)
            return nil

        case "userScripts.update":
            guard let changes = Self.decode([UserScript].self, call.payload["scripts"]) else { return BridgeError("Invalid user scripts") }
            var all = scripts
            for change in changes {
                guard let index = all.firstIndex(where: { $0.id == change.id }) else {
                    return BridgeError("Script with ID '\(change.id)' does not exist.")
                }
                var script = all[index]
                if let matches = change.matches { script.matches = matches }
                if let excludeMatches = change.excludeMatches { script.excludeMatches = excludeMatches }
                if let includeGlobs = change.includeGlobs { script.includeGlobs = includeGlobs }
                if let excludeGlobs = change.excludeGlobs { script.excludeGlobs = excludeGlobs }
                if let js = change.js { script.js = js }
                if let allFrames = change.allFrames { script.allFrames = allFrames }
                if let runAt = change.runAt { script.runAt = runAt }
                if let world = change.world { script.world = world }
                if let worldId = change.worldId { script.worldId = worldId }
                if let error = Self.validationError(script) { return BridgeError(error) }
                all[index] = script
            }
            await registry.userScripts.set(all, worlds: nil, for: extensionId)
            return nil

        case "userScripts.unregister":
            if let missing = ids?.first(where: { id in !scripts.contains { $0.id == id } }) {
                return BridgeError("Nonexistent script ID '\(missing)'")
            }
            await registry.userScripts.set(ids.map { ids in scripts.filter { !ids.contains($0.id) } } ?? [], worlds: nil, for: extensionId)
            return nil

        case "userScripts.getScripts":
            let matching = ids.map { ids in scripts.filter { ids.contains($0.id) } } ?? scripts
            return (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(matching))) ?? []

        case "userScripts.configureWorld":
            guard let world = Self.decode(World.self, call.payload["properties"]) else { return BridgeError("Invalid world properties") }
            if world.worldId?.hasPrefix("_") == true { return BridgeError("World IDs beginning with '_' are reserved.") }
            await registry.userScripts.set(nil, worlds: worlds.filter { $0.worldId != world.worldId } + [world], for: extensionId)
            return nil

        case "userScripts.getWorldConfigurations":
            return worlds.map { world in
                var properties: [String: Any] = ["messaging": world.messaging ?? false]
                properties["worldId"] = world.worldId
                properties["csp"] = world.csp
                return properties
            }

        case "userScripts.resetWorldConfiguration":
            let worldId = call.string("worldId")
            await registry.userScripts.set(nil, worlds: worlds.filter { $0.worldId != worldId }, for: extensionId)
            return nil

        case "userScripts.execute":
            return await execute(call)

        case "userScripts.portPost", "userScripts.portDisconnect":
            guard let portId = call.string("portId"), let port = ports[portId], port.extensionId == extensionId else { return nil }
            let disconnected = call.action == "userScripts.portDisconnect"
            if disconnected { ports[portId] = nil }
            _ = try? await port.webView?.callAsyncJavaScript(
                "globalThis.__liloUserScriptPort?.(portId, message, disconnected)",
                arguments: ["portId": portId, "message": call.payload["message"] ?? NSNull(), "disconnected": disconnected],
                in: port.frame,
                contentWorld: port.world
            )
            return nil

        case "userScripts.reply":
            guard let replyId = call.string("replyId"), pendingReplies[replyId]?.extensionId == extensionId,
                  let pending = pendingReplies.removeValue(forKey: replyId) else { return nil }
            pending.reply(call.payload["response"] ?? NSNull(), nil)
            return nil

        default:
            return nil
        }
    }

    /// `chrome.userScripts.execute` in a tab's frames, as Chrome's InjectionResult list: the main frame
    /// by default, `frameIds`, or every frame with `allFrames`. Frames the extension may not access are
    /// skipped, and the main frame's refusal is an error.
    private func execute(_ call: GapCall) async -> Any? {
        let registry = call.registry, extensionId = call.extensionId
        guard let injection = call.payload["injection"] as? [String: Any],
              let target = injection["target"] as? [String: Any],
              let sources = Self.decode([UserScript.Source].self, injection["js"]), !sources.isEmpty else {
            return BridgeError("Invalid injection")
        }
        if sources.contains(where: { ($0.code == nil) == ($0.file == nil) }) {
            return BridgeError("Each js source must specify exactly one of 'code' or 'file'.")
        }
        if target["documentIds"] != nil { return BridgeError("documentIds are not supported in Lilo") }
        let frameIds = (target["frameIds"] as? [NSNumber])?.map(\.intValue)
        if target["allFrames"] as? Bool == true, frameIds != nil { return BridgeError("Cannot specify both 'allFrames' and 'frameIds'.") }
        let world = injection["world"] as? String, worldId = injection["worldId"] as? String
        if world == "MAIN", worldId != nil { return BridgeError("worldId cannot be set in the MAIN world.") }
        let positions = call.payload["tabs"] as? [[String: Any]] ?? []
        guard let adapter = registry.tabAdapters(atPositions: positions, extensionId: extensionId).first ?? nil,
              let context = registry.context(for: extensionId),
              let directory = registry.loadedExtensions.first(where: { $0.id == extensionId })?.sourcePath,
              let (contentWorld, messaging) = registry.userScripts.world(world, worldId: worldId, extensionId: extensionId) else {
            return BridgeError("No tab with id: \(target["tabId"] ?? "")")
        }
        guard let engine = adapter.engineTab, engine.wake(), let webView = engine.view as? WKWebView, let url = webView.url else {
            return BridgeError("The tab has no page loaded")
        }
        guard context.hasAccess(to: url, in: adapter) else {
            return BridgeError("Cannot access contents of the page. Extension manifest must request permission to access the respective host.")
        }
        let frames = await Self.frames(of: webView).filter { frame in
            if let frameIds { return frameIds.contains(frame.id) }
            return target["allFrames"] as? Bool == true || frame.id == 0
        }
        if let frameIds, let missing = frameIds.first(where: { id in !frames.contains { $0.id == id } }) {
            return BridgeError("No frame with id \(missing) in tab with id \(target["tabId"] ?? "")")
        }
        if messaging {
            // A world no registered script uses has no handler on this tab yet; adding one twice raises.
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: contentWorld)
            controller.addScriptMessageHandler(self, contentWorld: contentWorld, name: Self.messageHandlerName)
        }
        let source = (messaging ? ExtensionUserScripts.messagingPrelude(extensionId: extensionId) : "")
            + ExtensionUserScripts.source(sources, extensionDirectory: directory)
        var results: [[String: Any]] = []
        for frame in frames {
            // A subframe the extension may not access is skipped, as Chrome skips it.
            if frame.id != 0, let frameURL = frame.info?.request.url, frameURL.scheme?.hasPrefix("http") == true,
               !context.hasAccess(to: frameURL, in: adapter) { continue }
            var result: [String: Any] = ["frameId": frame.id, "documentId": ""]
            do {
                result["result"] = try await Self.run(source, in: frame.info, of: webView, world: contentWorld) ?? NSNull()
            } catch let error as WKError where error.code == .javaScriptResultTypeIsUnsupported {
                result["result"] = NSNull()
            } catch {
                result["error"] = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            }
            results.append(result)
        }
        return results
    }

    /// Runs `source` as a script and returns its last value, awaited when it is a promise. Indirect eval
    /// keeps the script's completion value and global scope; a page CSP without 'unsafe-eval' refuses it
    /// in the MAIN world (isolated worlds are exempt), and the script then runs as is, unawaited.
    private static func run(_ source: String, in frame: WKFrameInfo?, of webView: WKWebView, world: WKContentWorld) async throws -> Any? {
        let refused = "__liloEvalRefused"
        let value = try await webView.callAsyncJavaScript(
            """
            let value;
            try { value = (0, eval)(source); } catch (e) {
              if (e instanceof EvalError && /unsafe-eval/.test(e.message)) return { [refused]: true };
              throw e;
            }
            return await value;
            """,
            arguments: ["source": source, "refused": refused],
            in: frame,
            contentWorld: world
        )
        guard (value as? [String: Any])?[refused] as? Bool == true else { return value }
        return try await webView.evaluateJavaScript(source, in: frame, contentWorld: world)
    }

    /// The tab's frames, the main one first as Chrome's frame 0; only the main frame when WebKit no
    /// longer exposes its frame tree.
    private static func frames(of webView: WKWebView) async -> [(id: Int, info: WKFrameInfo?)] {
        let selector = NSSelectorFromString("_frames:")
        guard webView.responds(to: selector) else { return [(0, nil)] }
        typealias Frames = @convention(c) (NSObject, Selector, @escaping @convention(block) (AnyObject?) -> Void) -> Void
        let tree: AnyObject? = await withCheckedContinuation { continuation in
            unsafeBitCast(webView.method(for: selector), to: Frames.self)(webView, selector) { tree in
                // Delivered on the main thread and read on the main actor only.
                nonisolated(unsafe) let tree = tree
                continuation.resume(returning: tree)
            }
        }
        var frames: [(id: Int, info: WKFrameInfo?)] = []
        // Every node is a `_WKFrameTreeNode`: checking the root covers its children.
        let infoSelector = NSSelectorFromString("info"), childFramesSelector = NSSelectorFromString("childFrames")
        var pending = [tree].compactMap { $0 as? NSObject }.filter { $0.responds(to: infoSelector) && $0.responds(to: childFramesSelector) }
        while !pending.isEmpty {
            let node = pending.removeFirst()
            if let info = node.value(forKey: "info") as? WKFrameInfo, let id = chromeFrameId(of: info) {
                frames.append((id, info))
            }
            pending += (node.value(forKey: "childFrames") as? [NSObject]) ?? []
        }
        return frames.isEmpty ? [(0, nil)] : frames
    }

    /// Chrome's frameId: 0 for the main frame, WebKit's own frame identifier for the others. Nil when
    /// WebKit no longer exposes it.
    static func chromeFrameId(of frame: WKFrameInfo) -> Int? {
        if frame.isMainFrame { return 0 }
        let handle = NSSelectorFromString("_handle")
        guard frame.responds(to: handle), let frameHandle = frame.value(forKey: "_handle") as? NSObject,
              frameHandle.responds(to: NSSelectorFromString("frameID")),
              let id = frameHandle.value(forKey: "frameID") as? NSNumber else { return nil }
        return id.intValue
    }

    /// Chrome's own checks; nil when the script is valid.
    private static func validationError(_ script: UserScript) -> String? {
        if script.id.isEmpty { return "Script's ID must not be empty" }
        if script.id.hasPrefix("_") { return "Script's ID '\(script.id)' must not start with '_'" }
        if script.matches?.isEmpty ?? true { return "Script with ID '\(script.id)' must specify at least one match." }
        if script.js?.isEmpty ?? true { return "Script with ID '\(script.id)' must specify at least one js source." }
        if script.js?.contains(where: { ($0.code == nil) == ($0.file == nil) }) == true {
            return "Script with ID '\(script.id)' must specify exactly one of 'code' or 'file' for each js source."
        }
        if let invalid = ((script.matches ?? []) + (script.excludeMatches ?? [])).first(where: { (try? WKWebExtension.MatchPattern(string: $0)) == nil }) {
            return "Script with ID '\(script.id)' has invalid match pattern '\(invalid)'."
        }
        if script.world == "MAIN", script.worldId != nil { return "Script with ID '\(script.id)' cannot set a worldId in the MAIN world." }
        return nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: value)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    // MARK: - WKScriptMessageHandlerWithReply

    /// The sending world's name, "lilo-us-<extension id>-<world id>", names the extension.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let worldName = message.world.name ?? ""
        guard let webView = message.webView, let registry = registryResolver(webView),
              let extensionId = registry.loadedExtensions.first(where: {
                  worldName.hasPrefix(ExtensionUserScripts.worldName(extensionId: $0.id, worldId: nil))
              })?.id,
              registry.access.states[extensionId]?.allowsUserScripts == true else {
            replyHandler(nil, "Could not establish connection. Receiving end does not exist.")
            return
        }
        let worldId = String(worldName.dropFirst(ExtensionUserScripts.worldName(extensionId: extensionId, worldId: nil).count))
        let worlds = registry.userScripts.registrations(of: extensionId)?.worlds ?? []
        let configuration = worlds.first { ($0.worldId ?? "") == worldId } ?? worlds.first { $0.worldId == nil }
        guard configuration?.messaging == true else {
            replyHandler(nil, "Messaging is not enabled for this user script world.")
            return
        }
        let body = message.body as? [String: Any] ?? [:]
        let frame = message.frameInfo
        switch body["kind"] as? String {
        case "port", "disconnect":
            guard let portId = body["portId"] as? String, ports[portId]?.extensionId == extensionId else { break }
            if body["kind"] as? String == "disconnect" {
                ports[portId] = nil
                registry.gapEvents.emit("runtime", "onUserScriptConnect", args: ["disconnect", portId], to: [extensionId])
            } else {
                registry.gapEvents.emit("runtime", "onUserScriptConnect", args: ["message", portId, body["message"] ?? NSNull()], to: [extensionId])
            }
            replyHandler(nil, nil)
            return
        default:
            break
        }
        let origin = frame.securityOrigin
        var sender: [String: Any] = [
            "id": extensionId,
            "url": frame.request.url?.absoluteString ?? "",
            "origin": origin.port == 0 ? "\(origin.protocol)://\(origin.host)" : "\(origin.protocol)://\(origin.host):\(origin.port)"
        ]
        if !worldId.isEmpty { sender["userScriptWorldId"] = worldId }
        sender["frameId"] = Self.chromeFrameId(of: frame)
        // The extension side turns the tab's position into its `tabs.Tab`.
        sender["tabPosition"] = registry.tabPosition(of: webView, extensionId: extensionId)

        if body["kind"] as? String == "connect" {
            guard let portId = body["portId"] as? String, ports[portId] == nil else { replyHandler(nil, nil); return }
            ports[portId] = Port(extensionId: extensionId, webView: webView, frame: frame, world: message.world)
            registry.gapEvents.emit("runtime", "onUserScriptConnect", args: ["connect", portId, body["name"] as? String ?? "", sender], to: [extensionId])
            replyHandler(nil, nil)
            return
        }
        let replyId = UUID().uuidString
        pendingReplies[replyId] = (extensionId, replyHandler)
        registry.gapEvents.emit("runtime", "onUserScriptMessage", args: [body["message"] ?? NSNull(), sender, replyId], to: [extensionId])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            self?.pendingReplies.removeValue(forKey: replyId)?.reply(nil, "Could not establish connection. Receiving end does not exist.")
        }
    }
}
