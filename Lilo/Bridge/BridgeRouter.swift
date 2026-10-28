import Foundation
import OSLog
import WebKit

/// Routes incoming bridge messages from the Svelte chrome to the appropriate handler.
/// Also provides the Swift-to-Svelte communication channel.
@MainActor
final class BridgeRouter: NSObject, WKScriptMessageHandler {

    private static let logger = Logger(liloCategory: "bridge")

    private(set) var handlers: [String: any BridgeHandler] = [:]
    private weak var chromeWebView: WKWebView?
    private var coalescer = BridgeEventCoalescer()
    private var coalescedEventFlushScheduled = false
    /// Raw events waiting for the end of the main-loop turn, behind the coalesced events drained
    /// before them: everything one turn sends ships in a single chrome JS call.
    private var outbox: [(event: String, data: [String: Any])] = []
    private var turnFlushScheduled = false
    private var lastSeq = 0
    /// The chrome JS call WebKit has not completed yet: at most one is in flight, so a starved or
    /// suspended chrome process never queues stale payloads; what waits ships as one batch after it.
    private var inFlightCallId: Int?
    private var lastCallId = 0

    /// While silenced the coalescing flush is suppressed and events ship in one batch on unsilence. Raw events still ship at the end of
    /// the turn (or when the call in flight completes): they are rare and must keep their position in the stream.
    var isSilenced = false {
        didSet { if oldValue && !isSilenced { flushPendingCoalescedEvents() } }
    }

    init(chromeWebView: WKWebView) {
        self.chromeWebView = chromeWebView
        super.init()
    }

    /// Registers a handler for its declared actions. A handler shared with the gap router declares
    /// only its UI actions: a gap action here would let the chrome page forge an extension's call.
    func register(handler: any BridgeHandler) {
        handler.handledActions.forEach { handlers[$0] = handler }
    }

    // MARK: - Caller authentication

    /// Only the trusted chrome UI's main frame may reach these privileged handlers: sub-frames are rejected outright, and the origin must be
    /// `lilo-chrome://` (registered only on the chrome web view); http/https are accepted only in DEBUG, for `LILO_UI_DEV_SERVER`.
    static func isTrustedChromeMessage(isMainFrame: Bool, originScheme: String) -> Bool {
        guard isMainFrame else { return false }
        let scheme = originScheme.lowercased()
        // Production: the chrome UI's own scheme.
        if scheme == ChromeUISchemeHandler.scheme { return true }
        #if DEBUG
        // Dev server (LILO_UI_DEV_SERVER) serves the chrome UI over http/https.
        return scheme == "http" || scheme == "https"
        #else
        return false
        #endif
    }

    // MARK: - WKScriptMessageHandler

    // WKScriptMessageHandler delivers on the main thread: parse + route synchronously in the same
    // turn. The Task exists only because handlers are async.
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            let frame = message.frameInfo
            guard Self.isTrustedChromeMessage(
                isMainFrame: frame.isMainFrame,
                originScheme: frame.securityOrigin.protocol
            ) else {
                Self.logger.warning(
                    "Rejected bridge message from untrusted context (mainFrame=\(frame.isMainFrame, privacy: .public), scheme=\(frame.securityOrigin.protocol, privacy: .public))"
                )
                return
            }

            guard let body = message.body as? [String: Any],
                  let bridgeMessage = BridgeMessage(dictionary: body),
                  let handler = handlers[bridgeMessage.action] else {
                return
            }

            Task { @MainActor in
                let signpost = PerfSignposts.bridge.beginInterval("handle", id: PerfSignposts.bridge.makeSignpostID(), bridgeMessage.action)
                _ = await handler.handle(message: bridgeMessage)
                PerfSignposts.bridge.endInterval("handle", signpost)
            }
        }
    }

    // MARK: - Swift to Svelte

    /// Sends an event to the Svelte UI: coalescable events wait for the 16 ms flush, the rest ship
    /// at the end of the current main-loop turn.
    func send(event: String, data: [String: Any] = [:]) {
        if coalescer.add(event: event, data: data) {
            scheduleCoalescedEventFlush()
            return
        }
        // Strict ordering: a raw event (full state, structural patch) must not overtake patches
        // still sitting in the 16 ms window, or the late flush would resurrect pre-event state.
        outbox += coalescer.drain()
        outbox.append((event, data))
        guard !turnFlushScheduled else { return }
        turnFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.turnFlushScheduled = false
                self.flushOutbox()
            }
        }
    }

    /// Forgets the call in flight, which a reloaded chrome page never completes, and ships what
    /// waited behind it. The reloaded page restarts its `stateSeq` tracking from the initial state.
    func resetInFlightCall() {
        inFlightCallId = nil
        flushOutbox()
    }

    /// Ships the outbox unless a call is in flight. Coalesced events move into it only then, so
    /// they keep merging while they wait; an occluded window keeps holding them.
    private func flushOutbox() {
        guard inFlightCallId == nil else { return }
        if !isSilenced { outbox += coalescer.drain() }
        shipOutbox()
    }

    /// Stamps and ships the outbox in one JS call; wire order == stamp order.
    private func shipOutbox() {
        guard !outbox.isEmpty else { return }
        if outbox.count == 1 {
            let pair = outbox[0]
            outbox.removeAll(keepingCapacity: true)
            dispatch(wireMessage(event: pair.event, data: pair.data))
            return
        }
        // A sidebar patch can carry its space's whole tree: of the patches that waited together, the newest whole tree of each
        // space supersedes every older tree and tree delta of that space.
        var spacesWithNewerTree = Set<String>()
        for index in outbox.indices.reversed() where outbox[index].event == "browserStatePatch" {
            guard var operations = outbox[index].data["operations"] as? [[String: Any]] else { continue }
            var superseded = false
            for operation in operations.indices.reversed() {
                guard let spaceId = operations[operation]["spaceId"] as? String else { continue }
                if spacesWithNewerTree.contains(spaceId) {
                    for key in ["treeItems", "upsertTreeItems", "removedTreeItemIds"] where operations[operation][key] != nil {
                        operations[operation][key] = nil
                        superseded = true
                    }
                } else if operations[operation]["treeItems"] != nil {
                    spacesWithNewerTree.insert(spaceId)
                }
            }
            if superseded { outbox[index].data["operations"] = operations }
        }
        var stamped: [[String: Any]] = []
        stamped.reserveCapacity(outbox.count)
        for pair in outbox { stamped.append(wireMessage(event: pair.event, data: pair.data)) }
        outbox.removeAll(keepingCapacity: true)
        logPayloadSize(stamped)
        callChromeJavaScript(
            "if (window.__lilo?.receiveBatch) { window.__lilo.receiveBatch(messages); } else { const bootstrap = window.__liloBootstrapEvents || (window.__liloBootstrapEvents = []); bootstrap.push(...messages); }",
            arguments: ["messages": stamped]
        )
    }

    /// State-sync events the UI sequences to detect a lost message (gap) and request a resync.
    private static let sequencedEvents: Set<String> = ["browserStatePatch", "browserStateChanged"]

    /// The wire form of `data`: `event` set, plus the next monotonic `stateSeq` for sequenced events
    /// (other events consume no seq). Runs at wire time (post-coalescer) so the counter matches the
    /// actual wire order exactly.
    private func wireMessage(event: String, data: [String: Any]) -> [String: Any] {
        var message = data
        message["event"] = event
        if Self.sequencedEvents.contains(event) {
            lastSeq += 1
            message["stateSeq"] = lastSeq
        }
        return message
    }

    /// Dispatches a pre-stamped message directly to the chrome without consuming a seq number.
    private func dispatch(_ message: [String: Any]) {
        logPayloadSize([message])
        callChromeJavaScript(
            "if (window.__lilo?.receive) { window.__lilo.receive(message); } else { const bootstrap = window.__liloBootstrapEvents || (window.__liloBootstrapEvents = []); bootstrap.push(message); }",
            arguments: ["message": message]
        )
    }

    /// Events shipped to the chrome, with their size in bytes only while Instruments records the
    /// "bridge" category: sizing serializes every message, which would skew a recorded session.
    private func logPayloadSize(_ messages: [[String: Any]]) {
        guard PerfSignposts.bridge.isEnabled else { return }
        let events = messages.compactMap { $0["event"] as? String }.joined(separator: "+")
        guard PerfSignposts.bridge.signposter.isEnabled, JSONSerialization.isValidJSONObject(messages) else {
            return PerfSignposts.bridge.emitEvent("send", events)
        }
        let bytes = (try? JSONSerialization.data(withJSONObject: messages))?.count ?? 0
        PerfSignposts.bridge.emitEvent("send", "\(events): \(bytes) bytes")
    }

    /// Test seam: when set, receives every outgoing chrome JS call instead of the web view, so
    /// wire order and stamped payloads are observable without a live page. The sink calls
    /// `completion` when the call would complete in WebKit.
    var javaScriptSink: (@MainActor (_ script: String, _ arguments: [String: Any], _ completion: @escaping @MainActor () -> Void) -> Void)?

    private func callChromeJavaScript(_ script: String, arguments: [String: Any]) {
        guard javaScriptSink != nil || chromeWebView != nil else { return }
        lastCallId += 1
        let callId = lastCallId
        inFlightCallId = callId
        let completion: @MainActor @Sendable () -> Void = { [weak self] in
            // A call forgotten by resetInFlightCall must not release the one that replaced it.
            guard let self, self.inFlightCallId == callId else { return }
            self.inFlightCallId = nil
            // Coalesced events alone keep their 16 ms window: shipping them now would cost a call
            // per round trip under a steady stream.
            if !self.outbox.isEmpty {
                self.flushOutbox()
            } else if !self.coalescer.pendingByEvent.isEmpty {
                self.scheduleCoalescedEventFlush()
            }
        }
        if let javaScriptSink {
            javaScriptSink(script, arguments, completion)
            return
        }
        var script = script, arguments = arguments
        // WebKit converts an object argument value by value on both sides; one JSON string crosses whole and the page parses it
        // several times faster, which matters for a sidebar patch of thousands of tabs.
        if JSONSerialization.isValidJSONObject(arguments), let json = try? JSONSerialization.data(withJSONObject: arguments),
           let payload = String(bytes: json, encoding: .utf8) {
            script = "const { \(arguments.keys.sorted().joined(separator: ", ")) } = JSON.parse(payload); \(script)"
            arguments = ["payload": payload]
        }
        // Without a user gesture: a state push must not hand the chrome a transient activation it can spend.
        guard let chromeWebView else { return }
        WebViewPrivateAccessors(chromeWebView).callAsyncWithoutUserGesture(script, arguments: arguments) { error in
            if let error { Self.logger.error("chrome JS call failed: \(error)") }
            completion()
        }
    }

    private func scheduleCoalescedEventFlush() {
        guard !coalescedEventFlushScheduled, !isSilenced, inFlightCallId == nil else { return }
        coalescedEventFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                // A flush scheduled before the window occluded must not ship to the invisible
                // window: hold the events; the isSilenced didSet flushes them on unsilence.
                if self.isSilenced {
                    self.coalescedEventFlushScheduled = false
                    return
                }
                self.flushPendingCoalescedEvents()
            }
        }
    }

    private func flushPendingCoalescedEvents() {
        coalescedEventFlushScheduled = false
        flushOutbox()
    }
}

/// Pure, testable accumulator for the 16 ms Swift-to-Svelte event-coalescing window. Holds no WebKit
/// or timer state: `BridgeRouter` owns the flush timer and JS dispatch and delegates the merge/key
/// decisions here so they can be unit-tested in isolation.
struct BridgeEventCoalescer {
    /// Events coalesced inside the flush window: `browserStatePatch` keyed per tab, `downloadUpdated` per download, the rest singletons whose
    /// latest value is all that matters. A burst must not pay one IPC per event, each force-flushing the pending patches.
    static let coalescedEvents: Set<String> = [
        "browserStatePatch", "trackersBlockedChanged", "downloadUpdated", "extensionsChanged", "contentInteraction",
        "hoveredLinkChanged", "commandKeyChanged", "terminalActivity", "agentActivity"
    ]

    /// Coalesced events with one buffered slot each: `trackersBlockedChanged` carries only the
    /// active tab's count, and `extensionsChanged` rows merge by id (see mergeExtensionRows).
    private static let singletonEvents: Set<String> = [
        "trackersBlockedChanged", "extensionsChanged", "contentInteraction", "hoveredLinkChanged",
        "commandKeyChanged", "terminalActivity", "agentActivity"
    ]

    /// Events whose payload is a full snapshot of one entity: a newer one replaces the buffered one
    /// wholesale. Key-merging them would keep stale optional keys, so a finished download would
    /// inherit the last tick's speed and eta.
    static let snapshotEvents: Set<String> = ["downloadUpdated"]

    /// Patch operation kinds that change sidebar structure; never buffered (see coalescingTabId).
    static let structuralOperationKinds: Set<String> = ["sidebarChanged"]

    private(set) var pendingByEvent: [String: [String: [String: Any]]] = [:]

    /// Accumulates `data` for a per-tab coalescing event and returns true; returns false when the
    /// event isn't coalescable and should be sent raw immediately.
    mutating func add(event: String, data: [String: Any]) -> Bool {
        guard let tabId = Self.coalescingTabId(for: event, data: data) else { return false }
        pendingByEvent[event, default: [:]][tabId] = Self.snapshotEvents.contains(event)
            ? data
            : pendingByEvent[event]?[tabId].map { Self.merge($0, data) } ?? data
        return true
    }

    /// Returns and clears every pending coalesced (event, data) pair. Buffered `browserStatePatch`
    /// payloads of one space ship as a single patch: the UI applies a patch's `tabUpdated`
    /// operations in one write per space, and the patch takes one `stateSeq`.
    mutating func drain() -> [(event: String, data: [String: Any])] {
        guard !pendingByEvent.isEmpty else { return [] }
        var result: [(event: String, data: [String: Any])] = []
        result.reserveCapacity(pendingByEvent.values.reduce(0) { $0 + $1.count })
        for (event, byTab) in pendingByEvent {
            guard event == "browserStatePatch", byTab.count > 1 else {
                for data in byTab.values { result.append((event: event, data: data)) }
                continue
            }
            var patchBySpace: [String: (index: Int, operations: [[String: Any]])] = [:]
            for data in byTab.values {
                guard let spaceId = data["changedSpaceId"] as? String,
                      let operations = data["operations"] as? [[String: Any]] else {
                    result.append((event: event, data: data))
                    continue
                }
                if patchBySpace[spaceId] == nil {
                    patchBySpace[spaceId] = (result.count, operations)
                    result.append((event: event, data: data))
                } else {
                    patchBySpace[spaceId]?.operations += operations
                }
            }
            for patch in patchBySpace.values where patch.operations.count > 1 {
                result[patch.index].data["operations"] = patch.operations
            }
        }
        pendingByEvent.removeAll(keepingCapacity: true)
        return result
    }

    /// Last-write-wins on every key except `operations`: concatenated, then consecutive `tabUpdated` ops for the same space and tab are
    /// key-merged into one, bounding held state during long occlusions.
    static func merge(_ existing: [String: Any], _ next: [String: Any]) -> [String: Any] {
        var merged = existing
        for (key, value) in next {
            if key == "operations",
               let existingOperations = merged[key] as? [[String: Any]],
               let nextOperations = value as? [[String: Any]] {
                merged[key] = collapseOperations(existingOperations + nextOperations)
            } else if key == "extensions",
                      let existingRows = merged[key] as? [[String: Any]],
                      let nextRows = value as? [[String: Any]] {
                merged[key] = mergeExtensionRows(existingRows, nextRows)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    /// `extensionsChanged` deltas: a newer row replaces the buffered one with the same id, keeping the
    /// buffered icon when the newer row leaves it out as unchanged.
    static func mergeExtensionRows(_ existing: [[String: Any]], _ next: [[String: Any]]) -> [[String: Any]] {
        var existingById: [String: [String: Any]] = [:]
        for row in existing { if let id = row["id"] as? String { existingById[id] = row } }
        var merged: [[String: Any]] = []
        merged.reserveCapacity(existing.count + next.count)
        for var row in next {
            if let id = row["id"] as? String, let buffered = existingById.removeValue(forKey: id), row["iconDataURL"] == nil {
                row["iconDataURL"] = buffered["iconDataURL"]
            }
            merged.append(row)
        }
        merged += existing.filter { ($0["id"] as? String).map { existingById[$0] != nil } ?? false }
        return merged
    }

    /// Walks `ops` and merges each `tabUpdated` into the previous when both share the same
    /// `spaceId` and `tab.id`. All other kinds, and `tabUpdated` ops for different tabs/spaces,
    /// are left in place. Order is preserved.
    static func collapseOperations(_ ops: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for op in ops {
            if let last = result.last,
               op["kind"] as? String == "tabUpdated",
               last["kind"] as? String == "tabUpdated",
               let opSpace = op["spaceId"] as? String,
               let lastSpace = last["spaceId"] as? String,
               opSpace == lastSpace,
               let opTab = op["tab"] as? [String: Any],
               let lastTab = last["tab"] as? [String: Any],
               let opTabId = opTab["id"] as? String,
               let lastTabId = lastTab["id"] as? String,
               opTabId == lastTabId {
                // Key-merge: last-wins on every tab field; preserve other op keys with last-wins too.
                var mergedOp = last
                for (k, v) in op where k != "tab" { mergedOp[k] = v }
                var mergedTab = lastTab
                for (k, v) in opTab { mergedTab[k] = v }
                mergedOp["tab"] = mergedTab
                result[result.count - 1] = mergedOp
            } else {
                result.append(op)
            }
        }
        return result
    }

    /// The coalescing key: the explicit `id`/`tabId`, or the single tab a `browserStatePatch` touches. Nil (zero or several tabs) sends
    /// the event raw rather than risk merging it into the wrong buffer.
    static func coalescingTabId(for event: String, data: [String: Any]) -> String? {
        guard coalescedEvents.contains(event) else { return nil }
        if singletonEvents.contains(event) { return event }
        // bridgeData carries the row id as Int64. Numeric ids never collide with the string tab
        // ids sharing this map.
        if event == "downloadUpdated" {
            return (data["id"] as? Int64).map(String.init)
        }
        // Structural patches (create/close) must keep their exact position in the event stream:
        // merging them into a buffered per-tab slot could reorder them against runtime updates.
        if let operations = data["operations"] as? [[String: Any]],
           operations.contains(where: { structuralOperationKinds.contains(($0["kind"] as? String) ?? "") }) {
            return nil
        }
        if let id = nonEmptyId((data["id"] as? String) ?? (data["tabId"] as? String)) {
            return id
        }
        guard event == "browserStatePatch",
              let operations = data["operations"] as? [[String: Any]] else { return nil }
        // Zero-allocation linear scan: track the first tab id; return nil on a second distinct one.
        var singleTabId: String?
        for operation in operations {
            guard let tab = operation["tab"] as? [String: Any],
                  let tabId = nonEmptyId(tab["id"] as? String) else { continue }
            if singleTabId == nil {
                singleTabId = tabId
            } else if singleTabId != tabId {
                return nil
            }
        }
        return singleTabId
    }

    private static func nonEmptyId(_ id: String?) -> String? {
        id?.isEmpty == false ? id : nil
    }
}

extension BridgeRouter {
    /// Ships the full site-permission list to the chrome after any permission mutation.
    func sendSitePermissionsLoaded(from store: SitePermissionStore) {
        send(event: "sitePermissionsLoaded", data: ["permissions": store.allPermissions().map { $0.bridgeData }])
    }

    /// Ships a handler's action outcome to the chrome as `event` `{action, message, level}`.
    func sendActionCompleted(_ event: String, action: String, message: String, level: String = "info") {
        send(event: event, data: ["action": action, "message": message, "level": level])
    }
}
