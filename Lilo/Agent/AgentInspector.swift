import Foundation
import UniformTypeIdentifiers
import WebKit

/// The built-in Web Inspector of one tab, connected without a window, that speaks WebKit's inspector
/// protocol for the agent's devtools tools and, through InspectorCDP.js, chrome.debugger. Connected on
/// the first such use, released with the tab or the detach.
@MainActor
final class AgentInspector {
    private weak var webView: WKWebView?
    let frontend: WKWebView
    private let files = FileServer()

    private static let script = ["AgentInspector", "InspectorCDP"]
        .compactMap { Bundle.appResourceURL($0, extension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        // Both are IIFEs: without the semicolon the second would be an argument to the first.
        .joined(separator: ";\n")
    /// The agent and extension debuggers share a tab's one frontend: the last one to let go closes it.
    private static let live = NSHashTable<AgentInspector>.weakObjects()

    private init(webView: WKWebView, frontend: WKWebView) {
        self.webView = webView
        self.frontend = frontend
    }

    /// `servesFiles` false keeps the agent's network_mock files handler of a frontend it shares.
    static func connect(to webView: WKWebView, servesFiles: Bool = true) async throws -> AgentInspector {
        // A connection that fails half way must not leave a frontend behind on the tab.
        func abandon(_ error: AgentToolError) -> AgentToolError {
            if !WebInspectorSupport.isVisible(for: webView), !live.allObjects.contains(where: { $0.webView === webView }) {
                _ = WebInspectorSupport.close(for: webView)
            }
            return error
        }
        guard let frontend = WebInspectorSupport.connect(for: webView) else {
            throw abandon(AgentToolError("The web inspector is unavailable on this macOS"))
        }
        // Windowless, the frontend is a hidden page: its timers, which dispatch every protocol message,
        // slow to seconds after a few minutes, and intercepted requests then outlive their rules.
        let preferences = frontend.configuration.preferences
        for key in ["hiddenPageDOMTimerThrottlingEnabled", "hiddenPageDOMTimerThrottlingAutoIncreases", "pageVisibilityBasedProcessSuppressionEnabled"]
        where preferences.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
            preferences.setValue(false, forKey: key)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            // A round trip, not just WI.mainTarget: right after a reconnect the old target still answers
            // while its commands fail, and a call can hang, so each probe gets half a second.
            let ready = await withCheckedContinuation { continuation in
                var answered = false
                let answer = { (value: Bool) in
                    guard !answered else { return }
                    answered = true
                    continuation.resume(returning: value)
                }
                frontend.callAsyncJavaScript("""
                    if (!window.WI?.mainTarget?.RuntimeAgent || !window.InspectorBackend) return false
                    return await WI.mainTarget.RuntimeAgent.evaluate.invoke({ expression: '1' }).then(() => true, () => false)
                    """, arguments: [:], in: nil, in: .page) { answer((try? $0.get()) as? Bool == true) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(false) }
            }
            if ready { break }
            guard ContinuousClock.now < deadline else { throw abandon(AgentToolError("The web inspector did not start")) }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let inspector = AgentInspector(webView: webView, frontend: frontend)
        if servesFiles {
            let controller = frontend.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "liloAgentFile", contentWorld: .page)
            controller.addScriptMessageHandler(inspector.files, contentWorld: .page, name: "liloAgentFile")
        }
        // Injected now so the hooks see everything from the connection on.
        do {
            _ = try await inspector.script("track", ["domains": [String]()])
        } catch let error as AgentToolError {
            throw abandon(error)
        }
        live.add(inspector)
        return inspector
    }

    /// Calls a function of AgentInspector.js, injecting the script first into a frontend that lacks it.
    func script(_ function: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        let call = "return await window.__liloInspector[name](args)"
        let parameters: [String: Any] = ["name": function, "args": arguments]
        do {
            let result = try await frontend.callAsyncJavaScript(
                "if (!window.__liloInspector) return '__lilo_missing'\n" + call, arguments: parameters, contentWorld: .page
            )
            guard result as? String == "__lilo_missing" else { return result }
            return try await frontend.callAsyncJavaScript(Self.script + "\n" + call, arguments: parameters, contentWorld: .page)
        } catch {
            throw AgentToolError((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }

    /// Whether the tab's inspector is connected through this frontend: closing and reopening Web
    /// Inspector replaces it.
    var isCurrent: Bool {
        let inspectorSelector = NSSelectorFromString("_inspector")
        let frontendSelector = NSSelectorFromString("inspectorWebView")
        guard let webView, WebInspectorSupport.isConnected(for: webView), webView.responds(to: inspectorSelector),
              let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: frontendSelector) else { return false }
        return inspector.perform(frontendSelector)?.takeUnretainedValue() === frontend
    }

    /// Lets network_mock rules answer with `path`: one file, or every file under it when it ends with a slash.
    func serve(_ path: String) {
        files.roots.insert(path)
    }

    /// The files of network_mock rules, read on each request so a rebuilt one comes fresh, and only under
    /// the paths the rules named.
    @MainActor
    private final class FileServer: NSObject, WKScriptMessageHandlerWithReply {
        var roots: Set<String> = []

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard let path = message.body as? String else { return replyHandler(nil, "Malformed file request") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard roots.contains(where: { url.path == $0 || $0.hasSuffix("/") && url.path.hasPrefix($0) }) else {
                return replyHandler(nil, "\(path) is outside the mocked paths")
            }
            Task {
                guard let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value else { return replyHandler(NSNull(), nil) }
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                replyHandler(["bodyBase64": data.base64EncodedString(), "mimeType": mimeType], nil)
            }
        }
    }

    func command(_ method: String, _ params: [String: Any]) async throws -> Any {
        try await script("send", ["method": method, "params": params]) ?? NSNull()
    }

    private static let setScaleSelector = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
    private static let scaleSelector = NSSelectorFromString("_overrideDeviceScaleFactor")

    /// The tab's forced device pixel ratio; 0 when the screen's applies.
    var deviceScaleFactor: CGFloat {
        get {
            guard let webView, webView.responds(to: Self.scaleSelector) else { return 0 }
            typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
            return unsafeBitCast(webView.method(for: Self.scaleSelector), to: Getter.self)(webView, Self.scaleSelector)
        }
        set {
            guard let webView, webView.responds(to: Self.setScaleSelector) else { return }
            // A CGFloat argument: perform(_:with:) would pass an object pointer instead.
            typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
            unsafeBitCast(webView.method(for: Self.setScaleSelector), to: Setter.self)(webView, Self.setScaleSelector, newValue)
        }
    }

    /// Undoes what the agent changed; an inspector the user is looking at stays open.
    func release() async {
        if deviceScaleFactor != 0 { deviceScaleFactor = 0 }
        _ = try? await script("reset")
        disconnect()
    }

    /// Closes the frontend unless the user looks at it or another connection still holds it.
    func disconnect() {
        Self.live.remove(self)
        guard let webView, !WebInspectorSupport.isVisible(for: webView),
              !Self.live.allObjects.contains(where: { $0.frontend === frontend }) else { return }
        _ = WebInspectorSupport.close(for: webView)
    }
}
