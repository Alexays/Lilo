import ScreenCaptureKit
import WebKit

/// `chrome.tabCapture` and `chrome.desktopCapture`: hands out Chrome's single-use stream ids, redeemed by getUserMedia through
/// the tab-share shim. Nothing runs between captures: ids expire lazily, on the next lookup.
@MainActor
final class CaptureBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "tabCapture.getMediaStreamId",
        "tabCapture.getCapturedTabs",
        "desktopCapture.chooseDesktopMedia",
        "desktopCapture.cancelChooseDesktopMedia"
    ]

    /// SCContentFilter is immutable once the picker made it, but not Sendable-annotated.
    enum Source: @unchecked Sendable {
        case tab(UUID)
        case screen(SCContentFilter)
    }

    /// Chrome keeps an unused stream id for 10 seconds (DesktopStreamsRegistry).
    static let streamIdLifetime: Duration = .seconds(10)

    struct Grant {
        let source: Source
        /// `chromeMediaSource` the id is redeemed with: 'tab' for tabCapture, 'desktop' for desktopCapture.
        let mediaSource: String
        /// The only origin whose frames may redeem the id.
        let consumerOrigin: String
        let extensionId: String
        weak var registry: ProfileExtensionRegistry?
        /// tabCapture: the captured tab's extension tab id and view, reported to the extension.
        let tabId: Int?
        weak var targetView: WKWebView?
        let expiresAt: ContinuousClock.Instant
    }

    private var grants: [String: Grant] = [:]
    /// Live tabCapture ferries by session token.
    private var captures: [String: Grant] = [:]
    private var pickers: [String: Task<Source?, Never>] = [:]

    /// Shows the desktopCapture picker for `sources` (Lilo's tab picker when it offers tabs, the
    /// system picker otherwise), titled with the extension's name. Set by `BrowserContext`.
    var picker: ((_ title: String, _ sources: Set<String>) async -> Source?)?

    func handle(_ call: GapCall) async -> Any? {
        let registry = call.registry, extensionId = call.extensionId
        guard let context = registry.context(for: extensionId) else { return BridgeError("Extension not loaded") }
        pruneExpiredGrants()
        switch call.action {
        case "tabCapture.getMediaStreamId":
            guard let position = call.payload["target"] as? [String: Any], let tabId = call.int("tabId"),
                  let adapter = registry.tabAdapters(atPositions: [position], extensionId: extensionId).first ?? nil,
                  let webView = adapter.webView(for: context) else {
                return BridgeError("Invalid tab specified.")
            }
            guard context.hasActiveUserGesture(in: adapter) else {
                return BridgeError("Extension has not been invoked for the current page (see activeTab permission). Chrome pages cannot be captured.")
            }
            let inUse = (Array(grants.values) + Array(captures.values)).contains { grant in
                grant.extensionId == extensionId && grant.targetView === webView
            }
            guard !inUse else { return BridgeError("Cannot capture a tab with an active stream.") }
            let consumer = consumerOrigin(call.payload["consumer"] as? [String: Any], registry: registry, extensionId: extensionId, context: context)
            guard let consumer else { return BridgeError("Invalid tab specified.") }
            guard case .success(let origin) = consumer else { return BridgeError("URL scheme for the specified tab is not secure.") }
            return grant(Grant(
                source: .tab(adapter.tabId), mediaSource: "tab", consumerOrigin: origin, extensionId: extensionId, registry: registry,
                tabId: tabId, targetView: webView, expiresAt: .now + Self.streamIdLifetime
            ))

        case "tabCapture.getCapturedTabs":
            return captures.values.filter { $0.extensionId == extensionId }.map(captureInfo(status: "active"))

        case "desktopCapture.chooseDesktopMedia":
            let sources = Set(call.payload["sources"] as? [String] ?? [])
            guard !sources.isDisjoint(with: ["screen", "window", "tab"]) else {
                return BridgeError("At least one source type must be specified.")
            }
            guard let consumer = consumerOrigin(call.payload["target"] as? [String: Any], registry: registry, extensionId: extensionId, context: context) else {
                return BridgeError("Invalid tab specified.")
            }
            guard case .success(let origin) = consumer else { return BridgeError("URL scheme for the specified tab is not secure.") }
            let key = "\(registry.profileId)/\(extensionId)/\(call.int("requestId") ?? 0)"
            let title = context.webExtension.displayName ?? extensionId
            let task = Task { await picker?(title, sources) }
            pickers[key] = task
            let source = await task.value
            pickers[key] = nil
            guard let source else { return ["streamId": ""] }
            let streamId = grant(Grant(
                source: source, mediaSource: "desktop", consumerOrigin: origin, extensionId: extensionId, registry: registry,
                tabId: nil, targetView: nil, expiresAt: .now + Self.streamIdLifetime
            ))
            return ["streamId": streamId, "canRequestAudioTrack": false]

        case "desktopCapture.cancelChooseDesktopMedia":
            pickers["\(registry.profileId)/\(extensionId)/\(call.int("requestId") ?? 0)"]?.cancel()
            return nil

        default:
            return nil
        }
    }

    /// Takes the grant behind `streamId` when `origin` may use it with `mediaSource`; the id is
    /// spent only then, as Chrome leaves it to the consumer it names.
    func redeem(_ streamId: String, mediaSource: String, origin: String) -> Grant? {
        pruneExpiredGrants()
        guard let grant = grants[streamId], grant.mediaSource == mediaSource, grant.consumerOrigin == origin else { return nil }
        grants[streamId] = nil
        return grant
    }

    /// A redeemed tabCapture grant became the ferry session `token`.
    func captureStarted(token: String, grant: Grant) {
        guard grant.tabId != nil else { return }
        captures[token] = grant
        emitStatus(of: grant, "pending")
        emitStatus(of: grant, "active")
    }

    func sessionEnded(token: String) {
        guard let grant = captures.removeValue(forKey: token) else { return }
        emitStatus(of: grant, "stopped")
    }

    private func grant(_ grant: Grant) -> String {
        let streamId = UUID().uuidString
        grants[streamId] = grant
        return streamId
    }

    private func pruneExpiredGrants() {
        let now = ContinuousClock.Instant.now
        grants = grants.filter { $0.value.expiresAt > now }
    }

    private enum ConsumerOrigin { case success(String), insecure }

    /// The origin allowed to redeem: the extension's own, or that of the tab at `position`, which must be
    /// secure. Nil when the tab is unknown.
    private func consumerOrigin(_ position: [String: Any]?, registry: ProfileExtensionRegistry, extensionId: String, context: WKWebExtensionContext) -> ConsumerOrigin? {
        guard let position else {
            return .success("chrome-extension://\(extensionId)")
        }
        guard let adapter = registry.tabAdapters(atPositions: [position], extensionId: extensionId).first ?? nil,
              let url = adapter.webView(for: context)?.url else { return nil }
        guard url.scheme == "https", let host = url.host else { return .insecure }
        return .success(url.port.map { "https://\(host):\($0)" } ?? "https://\(host)")
    }

    private func captureInfo(status: String) -> (Grant) -> [String: Any] {
        { grant in
            [
                "tabId": grant.tabId ?? -1,
                "status": status,
                "fullscreen": grant.targetView?.fullscreenState == .inFullscreen
            ]
        }
    }

    private func emitStatus(of grant: Grant, _ status: String) {
        grant.registry?.gapEvents.emit("tabCapture", "onStatusChanged", args: [captureInfo(status: status)(grant)], to: [grant.extensionId])
    }
}
