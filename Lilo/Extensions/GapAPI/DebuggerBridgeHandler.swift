import AppKit
import WebKit
import os

extension Notification.Name {
    /// Object: the `WKWebViewTab` whose page goes away (its tab closed or was discarded).
    static let webViewTabWillTearDown = Notification.Name("fr.arouillard.lilo.webViewTabWillTearDown")
}

/// chrome.debugger over the tab's Web Inspector, with InspectorCDP.js translating CDP to WebKit's protocol; screenshots stay in
/// the inspector, while navigation, PDF, input and device scale are native. Nothing runs while no extension is attached.
@MainActor
final class DebuggerBridgeHandler: NSObject, GapHandler, BridgeHandler, WKScriptMessageHandler {
    static let shared = DebuggerBridgeHandler()
    private static let logger = Logger(liloCategory: "debugger")

    let gapActions: Set<String> = ["debugger.attach", "debugger.detach", "debugger.sendCommand", "debugger.getTargets"]
    let handledActions: Set<String> = ["getExtensionDebuggers", "cancelExtensionDebugging"]

    @MainActor
    private final class Session {
        let extensionId: String
        let extensionName: String
        weak var registry: ProfileExtensionRegistry?
        /// The target as the extension named it at attach; its events carry it back.
        let debuggee: [String: Any]
        let engine: WKWebViewTab
        var inspector: AgentInspector
        var domains: Set<String> = []
        var urlObservation: NSKeyValueObservation?
        var scaled = false
        /// A `rawKeyDown` that types, sent with the `char` that follows it so the text goes in once.
        var pendingKey: (key: String, keyCode: UInt16?)?

        init(extensionId: String, extensionName: String, registry: ProfileExtensionRegistry, debuggee: [String: Any], engine: WKWebViewTab, inspector: AgentInspector) {
            self.extensionId = extensionId
            self.extensionName = extensionName
            self.registry = registry
            self.debuggee = debuggee
            self.engine = engine
            self.inspector = inspector
        }

        /// The banner's id for the extension: its id alone is not unique across profiles.
        var owner: String { "\(registry?.profileId.uuidString ?? "")/\(extensionId)" }
    }

    private var sessions: [Session] = []
    private let routers = NSHashTable<BridgeRouter>.weakObjects()
    nonisolated(unsafe) private var observers: [Any] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .webViewTabWillTearDown, object: nil, queue: .main) { [weak self] note in
                guard let object = note.object else { return }
                let engine = ObjectIdentifier(object as AnyObject)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for session in self.sessions where ObjectIdentifier(session.engine) == engine {
                        self.end(session, reason: "target_closed", pageGone: true)
                    }
                }
            },
            center.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
                guard let profileId = note.userInfo?["profileId"] as? UUID, let extensionId = note.userInfo?["extensionId"] as? String else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for session in self.sessions where session.extensionId == extensionId && session.registry?.profileId == profileId {
                        self.end(session, reason: nil)
                    }
                }
            }
        ]
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// A window's bridge, which shows the debugging banner and cancels it.
    func attach(to router: BridgeRouter) {
        router.register(handler: self)
        routers.add(router)
    }

    // MARK: - GapHandler

    func handle(_ call: GapCall) async -> Any? {
        let debuggee = call.payload["target"] as? [String: Any] ?? [:]
        switch call.action {
        case "debugger.attach":
            return await attach(call, debuggee: debuggee)
        case "debugger.detach":
            guard let session = session(for: debuggee, call) else { return BridgeError("Debugger is not attached to the \(Self.describe(debuggee)).") }
            end(session, reason: nil)
            return nil
        case "debugger.sendCommand":
            guard let session = session(for: debuggee, call) else { return BridgeError("Debugger is not attached to the \(Self.describe(debuggee)).") }
            return await send(call.string("method") ?? "", call.payload["params"] as? [String: Any] ?? [:], in: session)
        case "debugger.getTargets":
            return targets(call)
        default:
            return nil
        }
    }

    /// "tab with id: 3", as Chrome's errors name a debuggee.
    private static func describe(_ debuggee: [String: Any]) -> String {
        let (type, id) = kind(of: debuggee)
        return "\(type) with id: \(id)"
    }

    private static func kind(of debuggee: [String: Any]) -> (type: String, id: String) {
        if let tabId = debuggee["tabId"] as? NSNumber { return ("tab", tabId.stringValue) }
        if let extensionId = debuggee["extensionId"] as? String { return ("background page", extensionId) }
        return ("target", debuggee["targetId"] as? String ?? "")
    }

    private func session(for debuggee: [String: Any], _ call: GapCall) -> Session? {
        sessions.first { session in
            guard session.extensionId == call.extensionId, session.registry === call.registry else { return false }
            if let tabId = debuggee["tabId"] as? NSNumber { return session.debuggee["tabId"] as? NSNumber == tabId }
            if let targetId = debuggee["targetId"] as? String { return session.engine.id.uuidString == targetId }
            return false
        }
    }

    /// Chrome's checks, in its order: protocol version, target, the URL it shows, then one debugger
    /// per extension and tab. The `debugger` permission grants every host, as in Chrome.
    private func attach(_ call: GapCall, debuggee: [String: Any]) async -> Any? {
        let version = call.string("requiredVersion") ?? ""
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "1", let minor = Int(parts[1]), (0...3).contains(minor) else {
            return BridgeError("Requested protocol version is not supported: \(version).")
        }
        let (type, id) = Self.kind(of: debuggee)
        let registry = call.registry
        guard let context = registry.context(for: call.extensionId) else { return BridgeError("No \(type) with given id \(id).") }
        let adapter: TabExtensionAdapter?
        if debuggee["tabId"] != nil, let position = call.payload["tab"] as? [String: Any] {
            adapter = registry.tabAdapters(atPositions: [position], extensionId: call.extensionId).first ?? nil
        } else if let targetId = debuggee["targetId"] as? String {
            adapter = Self.tabs(of: registry, context: context).first { $0.adapter.tabId.uuidString == targetId }?.adapter
        } else {
            // MV3 extensions have no background page.
            adapter = nil
        }
        guard let adapter else { return BridgeError("No \(type) with given id \(id).") }
        if let restriction = Self.restriction(of: adapter.url(for: context), for: context) { return BridgeError(restriction) }
        guard let engine = adapter.engineTab else { return BridgeError("Cannot attach to this target.") }
        let attached = { [self] in sessions.contains { $0.extensionId == call.extensionId && $0.registry === registry && $0.engine === engine } }
        if attached() { return BridgeError("Another debugger is already attached to the \(type) with id: \(id).") }
        let inspector: AgentInspector
        do {
            inspector = try await AgentInspector.connect(to: engine.wkWebView, servesFiles: false)
        } catch {
            Self.logger.error("debugger attach failed: \(error.localizedDescription, privacy: .public)")
            return BridgeError("Cannot attach to this target.")
        }
        // Another attach, or the tab closing, may have come while the inspector started.
        guard !attached(), registry.tabPosition(of: adapter, extensionId: call.extensionId) != nil else {
            inspector.disconnect()
            return BridgeError(attached() ? "Another debugger is already attached to the \(type) with id: \(id)." : "No \(type) with given id \(id).")
        }
        let session = Session(
            extensionId: call.extensionId, extensionName: context.webExtension.displayName ?? call.extensionId,
            registry: registry, debuggee: debuggee, engine: engine, inspector: inspector
        )
        sessions.append(session)
        Self.receiveEvents(of: inspector, handler: self)
        // Chrome detaches when the tab shows a page the extension may not debug.
        session.urlObservation = engine.wkWebView.observe(\.url, options: [.new]) { [weak self, weak session] webView, _ in
            MainActor.assumeIsolated {
                guard let self, let session, let context = session.registry?.context(for: session.extensionId),
                      Self.restriction(of: webView.url, for: context) != nil else { return }
                self.end(session, reason: "target_closed")
            }
        }
        publish()
        return nil
    }

    /// Why an extension may not debug a tab showing `url`, in Chrome's words; nil when it may.
    static func restriction(of url: URL?, for context: WKWebExtensionContext) -> String? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return ChromeMasquerade.isStoreURL(url) ? "The extensions gallery cannot be scripted." : nil
        case "about", "data", "blob":
            return nil
        case "file":
            return context.hasAccess(to: url) ? nil : "Cannot attach to this target."
        case "chrome-extension":
            return url.host == context.baseURL.host ? nil : "Cannot access a chrome-extension:// URL of different extension"
        default:
            return "Cannot access a chrome:// URL"
        }
    }

    /// The frontend posts the events of the domains its sessions enabled; one handler per frontend.
    private static func receiveEvents(of inspector: AgentInspector, handler: WKScriptMessageHandler) {
        let controller = inspector.frontend.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "liloDebuggerEvent", contentWorld: .page)
        controller.add(handler, contentWorld: .page, name: "liloDebuggerEvent")
    }

    /// Ends a session; `reason` fires `onDetach`, which an extension's own detach does not. A gone page
    /// never answers, so nothing is undone on it.
    private func end(_ session: Session, reason: String?, pageGone: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        session.urlObservation = nil
        if session.scaled { session.inspector.deviceScaleFactor = 0 }
        if let reason, let registry = session.registry {
            registry.gapEvents.emit("debugger", "onDetach", args: [session.debuggee, reason], to: [session.extensionId])
        }
        let inspector = session.inspector
        let shared = sessions.contains { $0.inspector.frontend === inspector.frontend }
        Task {
            if !shared {
                inspector.frontend.configuration.userContentController.removeScriptMessageHandler(forName: "liloDebuggerEvent", contentWorld: .page)
                if !pageGone { _ = try? await inspector.script("cdpReset") }
            } else if !pageGone {
                await syncDomains(of: inspector)
            }
            inspector.disconnect()
        }
        publish()
    }

    // MARK: - Commands

    private static func protocolError(_ code: Int, _ message: String) -> BridgeError {
        // Chrome's lastError is the protocol error as JSON, keys sorted.
        let data = try? JSONSerialization.data(withJSONObject: ["code": code, "message": message], options: [.sortedKeys, .withoutEscapingSlashes])
        return BridgeError(data.flatMap { String(data: $0, encoding: .utf8) } ?? message)
    }

    private func send(_ method: String, _ params: [String: Any], in session: Session) async -> Any? {
        let engine = session.engine
        let webView = engine.wkWebView
        // A suspended page answers nothing.
        if engine.isFrozen { engine.resume() }
        if !session.inspector.isCurrent {
            // The user closed the Web Inspector they had open on the tab, and the connection with it.
            guard let inspector = try? await AgentInspector.connect(to: webView, servesFiles: false), sessions.contains(where: { $0 === session }) else {
                return Self.protocolError(-32000, "Target closed")
            }
            for other in sessions where other.inspector.frontend === session.inspector.frontend { other.inspector = inspector }
            Self.receiveEvents(of: inspector, handler: self)
            await syncDomains(of: inspector)
        }
        let number = { (key: String) in (params[key] as? NSNumber)?.doubleValue }
        switch method {
        case "Page.navigate":
            guard let url = (params["url"] as? String).flatMap(URL.init(string:)), url.scheme != nil else {
                return Self.protocolError(-32000, "Cannot navigate to invalid URL")
            }
            let tree = (try? await session.inspector.script("cdpSend", ["method": "Page.getFrameTree", "params": [:]])) as? [String: Any]
            let frame = ((tree?["result"] as? [String: Any])?["frameTree"] as? [String: Any])?["frame"] as? [String: Any]
            engine.loadURL(url)
            return ["frameId": frame?["id"] ?? "", "loaderId": frame?["loaderId"] ?? ""] as [String: Any]
        case "Page.printToPDF":
            guard let data = try? await webView.pdf(configuration: WKPDFConfiguration()) else { return Self.protocolError(-32000, "Printing failed") }
            return ["data": data.base64EncodedString()]
        case "Emulation.setDeviceMetricsOverride", "Emulation.clearDeviceMetricsOverride":
            let scale = method == "Emulation.clearDeviceMetricsOverride" ? 0 : number("deviceScaleFactor") ?? 0
            session.inspector.deviceScaleFactor = CGFloat(scale)
            session.scaled = scale != 0
            return [String: Any]()
        case "Input.dispatchMouseEvent":
            return await dispatchMouse(params, to: webView)
        case "Input.dispatchKeyEvent":
            return await dispatchKey(params, to: webView, in: session)
        default:
            break
        }
        let reply: [String: Any]
        do {
            reply = try await session.inspector.script("cdpSend", ["method": method, "params": params]) as? [String: Any] ?? [:]
        } catch {
            return Self.protocolError(-32000, error.localizedDescription)
        }
        // The session may have ended while the command ran.
        guard sessions.contains(where: { $0 === session }) else { return Self.protocolError(-32000, "Detached while handling command.") }
        if let error = reply["error"] as? [String: Any] {
            return Self.protocolError((error["code"] as? NSNumber)?.intValue ?? -32000, error["message"] as? String ?? "")
        }
        let parts = method.split(separator: ".")
        if parts.count == 2, parts[1] == "enable" || parts[1] == "disable" {
            if parts[1] == "enable" { session.domains.insert(String(parts[0])) } else { session.domains.remove(String(parts[0])) }
            await syncDomains(of: session.inspector)
        }
        if let events = reply["events"] as? [[String: Any]], let registry = session.registry {
            for event in events {
                registry.gapEvents.emit("debugger", "onEvent", args: [session.debuggee, event["method"] ?? "", event["params"] ?? [:]], to: [session.extensionId])
            }
        }
        return reply["result"] ?? [String: Any]()
    }

    private func syncDomains(of inspector: AgentInspector) async {
        let domains = Set(sessions.filter { $0.inspector.frontend === inspector.frontend }.flatMap(\.domains))
        _ = try? await inspector.script("cdpDomains", ["domains": Array(domains)])
    }

    /// CDP's modifiers bit field: Alt 1, Ctrl 2, Meta 4, Shift 8.
    private static func modifiers(_ params: [String: Any]) -> NSEvent.ModifierFlags {
        let bits = (params["modifiers"] as? NSNumber)?.intValue ?? 0
        let flags: [(bit: Int, flag: NSEvent.ModifierFlags)] = [(1, .option), (2, .control), (4, .command), (8, .shift)]
        return NSEvent.ModifierFlags(flags.filter { bits & $0.bit != 0 }.map(\.flag))
    }

    /// Waits until the page saw the `type` DOM event `send` causes, a third of a second at most (one
    /// that never comes, in a frame): Chrome answers an Input command once the page handled it, and
    /// WebKit queues key events, so a later command could overtake them.
    private static func untilPageSees(_ type: String, in webView: WKWebView, _ send: () -> Void) async {
        await withCheckedContinuation { (seen: CheckedContinuation<Void, Never>) in
            // Armed by a call that goes out before the event: WebKit keeps that order.
            webView.callAsyncJavaScript("""
                return await new Promise(resolve => {
                    const done = () => { clearTimeout(timer); removeEventListener(type, done, true); resolve() }
                    const timer = setTimeout(done, 300)
                    addEventListener(type, done, true)
                })
                """, arguments: ["type": type], in: nil, in: AgentInput.world) { _ in seen.resume() }
            send()
        }
    }

    private func dispatchMouse(_ params: [String: Any], to webView: WKWebView) async -> Any? {
        // CDP points are CSS pixels of the viewport, AgentInput's are the web view's.
        let zoom = webView.pageZoom
        let point = CGPoint(x: ((params["x"] as? NSNumber)?.doubleValue ?? 0) * zoom, y: ((params["y"] as? NSNumber)?.doubleValue ?? 0) * zoom)
        let button = params["button"] as? String ?? "none"
        let clickCount = (params["clickCount"] as? NSNumber)?.intValue ?? 1
        let modifiers = Self.modifiers(params)
        let type: NSEvent.EventType
        switch (params["type"] as? String ?? "", button) {
        case ("mousePressed", "right"): type = .rightMouseDown
        case ("mousePressed", "middle"): type = .otherMouseDown
        case ("mousePressed", _): type = .leftMouseDown
        case ("mouseReleased", "right"): type = .rightMouseUp
        case ("mouseReleased", "middle"): type = .otherMouseUp
        case ("mouseReleased", _): type = .leftMouseUp
        case ("mouseMoved", _): type = ((params["buttons"] as? NSNumber)?.intValue ?? 0) & 1 != 0 || button == "left" ? .leftMouseDragged : .mouseMoved
        case ("mouseWheel", _):
            let delta = { (key: String) in CGFloat((params[key] as? NSNumber)?.doubleValue ?? 0) * zoom }
            await Self.untilPageSees("wheel", in: webView) {
                AgentInput.scroll(webView, at: point, deltaX: delta("deltaX"), deltaY: delta("deltaY"), showsCursor: false)
            }
            return [String: Any]()
        default:
            return Self.protocolError(-32602, "Invalid parameters: type")
        }
        let domEvent = switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: "mousedown"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: "mouseup"
        default: "mousemove"
        }
        await Self.untilPageSees(domEvent, in: webView) {
            AgentInput.mouseEvent(type, webView, at: point, clickCount: clickCount, modifiers: modifiers)
        }
        return [String: Any]()
    }

    private func dispatchKey(_ params: [String: Any], to webView: WKWebView, in session: Session) async -> Any? {
        let key = params["key"] as? String ?? ""
        let text = params["text"] as? String ?? ""
        let keyCode = (params["nativeVirtualKeyCode"] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) }
        let modifiers = Self.modifiers(params)
        switch params["type"] as? String ?? "" {
        case "keyDown":
            await Self.untilPageSees("keydown", in: webView) {
                AgentInput.keyEvent(webView, down: true, key: key, text: text, keyCode: keyCode, modifiers: modifiers)
            }
        case "rawKeyDown":
            // A key that types waits for its char; one that does not (arrows, Backspace) goes now.
            if key.count == 1 || key == "Enter" || key == "Tab" {
                session.pendingKey = (key, keyCode)
            } else {
                await Self.untilPageSees("keydown", in: webView) {
                    AgentInput.keyEvent(webView, down: true, key: key, text: "", keyCode: keyCode, modifiers: modifiers)
                }
            }
        case "char":
            if let pending = session.pendingKey {
                await Self.untilPageSees("keydown", in: webView) {
                    AgentInput.keyEvent(webView, down: true, key: pending.key, text: text, keyCode: pending.keyCode, modifiers: modifiers)
                }
            } else {
                await AgentInput.type(webView, text: text)
            }
            session.pendingKey = nil
        case "keyUp":
            session.pendingKey = nil
            await Self.untilPageSees("keyup", in: webView) {
                AgentInput.keyEvent(webView, down: false, key: key, text: text, keyCode: keyCode, modifiers: modifiers)
            }
        default:
            return Self.protocolError(-32602, "Invalid parameters: type")
        }
        return [String: Any]()
    }

    // MARK: - getTargets

    private static func tabs(of registry: ProfileExtensionRegistry, context: WKWebExtensionContext) -> [(adapter: TabExtensionAdapter, position: [String: Int])] {
        registry.extensionWindows.enumerated().flatMap { windowPosition, window in
            window.tabs(for: context).enumerated().compactMap { index, tab in
                (tab as? TabExtensionAdapter).map { ($0, ["windowPosition": windowPosition, "index": index]) }
            }
        }
    }

    /// Every tab as a page target; the bridge turns each position into WebKit's tab id.
    private func targets(_ call: GapCall) -> Any? {
        guard let context = call.registry.context(for: call.extensionId) else { return [] }
        return Self.tabs(of: call.registry, context: context).map { tab -> [String: Any] in
            [
                "tab": tab.position,
                "id": tab.adapter.tabId.uuidString,
                "title": tab.adapter.title(for: context) ?? "",
                "url": tab.adapter.url(for: context)?.absoluteString ?? "",
                "attached": sessions.contains { $0.engine === tab.adapter.engineTab }
            ]
        }
    }

    // MARK: - Events

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else { return }
        let domain = String(method.prefix { $0 != "." })
        let params = body["params"] ?? [String: Any]()
        for session in sessions where session.domains.contains(domain) && session.inspector.frontend === message.webView {
            session.registry?.gapEvents.emit("debugger", "onEvent", args: [session.debuggee, method, params], to: [session.extensionId])
        }
    }

    // MARK: - Banner

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {
        case "getExtensionDebuggers":
            publish()
        case "cancelExtensionDebugging":
            let owner = message.string("id")
            for session in sessions where session.owner == owner { end(session, reason: "canceled_by_user") }
        default:
            break
        }
        return nil
    }

    /// Tells every window which extensions debug a tab now.
    private func publish() {
        var seen: Set<String> = []
        let debuggers = sessions.filter { seen.insert($0.owner).inserted }
            .map { ["id": $0.owner, "name": $0.extensionName] }
            .sorted { $0["name"] ?? "" < $1["name"] ?? "" }
        for router in routers.allObjects { router.send(event: "extensionDebuggers", data: ["debuggers": debuggers]) }
    }
}
