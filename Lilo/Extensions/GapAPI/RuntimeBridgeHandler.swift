import Foundation
import WebKit

/// The `chrome.runtime` calls WebKit lacks: `requestUpdateCheck`, against Lilo's update checker; whether the
/// worker listens to `runtime.onMessage`, which picks Chrome's error for a page's message nobody answers (a
/// worker that has not reported its listeners yet counts as listening); and messages and ports to another
/// extension of the profile, relayed to its `onMessageExternal` and `onConnectExternal`, from its pages, its worker
/// and, through the worker, its content scripts.
@MainActor
final class RuntimeBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "runtime.requestUpdateCheck", "runtime.workerListensToMessages",
        "runtime.sendExternal", "runtime.answerExternal", "runtime.connectExternal", "runtime.portAccept", "runtime.portDecline",
        "runtime.portPost", "runtime.portDisconnect"
    ]

    static let noReceiver = "Could not establish connection. Receiving end does not exist."
    /// Chrome stops waiting on an extension's answer once its worker has run this long for it.
    private static let answerTimeout: Duration = .seconds(300)

    /// `@unchecked Sendable`: JSON values built and read on the main actor.
    private struct Answer: @unchecked Sendable {
        let value: [String: Any]
    }

    /// A message to another extension, waiting on its answer.
    private struct Message {
        let target: String
        weak var registry: ProfileExtensionRegistry?
        let answer: CheckedContinuation<Answer, Never>
        let timeout: Task<Void, Never>
    }

    /// A port between two extensions of one profile, which disconnects once either end's page goes, as in Chrome.
    private struct Port {
        let opener: String
        let target: String
        /// The channel of the page that opened it; nil for the worker.
        let openerChannel: Int?
        /// The target's pages that took it: it goes with the last one, unless the target's worker may hold it too.
        var targetChannels: Set<Int> = []
        /// Also true while the target's worker has not reported its listeners: it hears the port, and declines it without one.
        var targetWorkerListens: Bool
        /// Whether a page of the target heard the port: one then takes it.
        let targetPagesHeard: Bool
        weak var registry: ProfileExtensionRegistry?

        func other(than extensionId: String) -> String? {
            extensionId == opener ? target : extensionId == target ? opener : nil
        }
    }

    private var messages: [String: Message] = [:]
    private var ports: [String: Port] = [:]
    private var nextId = 0
    nonisolated(unsafe) private var observers: [Any] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
            guard let extensionId = note.userInfo?["extensionId"] as? String else { return }
            let registry = note.object as? ProfileExtensionRegistry
            MainActor.assumeIsolated { self?.extensionDidUnload(extensionId, registry: registry) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .extensionPageChannelDidClose, object: nil, queue: .main) { [weak self] note in
            guard let extensionId = note.userInfo?["extensionId"] as? String, let channel = note.userInfo?["channel"] as? Int else { return }
            let events = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.pageDidClose(channel, extensionId: extensionId, events: events) }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        let events = call.registry.gapEvents
        switch call.action {
        case "runtime.workerListensToMessages":
            return events.reportedListeners(of: call.extensionId)?.contains("runtime.onMessage") ?? true

        case "runtime.sendExternal":
            guard let target = call.string("id"), let sender = sender(of: call, reaching: target, event: "onMessageExternal") else {
                return BridgeError(Self.noReceiver)
            }
            nextId += 1
            let id = String(nextId)
            let message = call.payload["message"] ?? NSNull()
            let answer = await withCheckedContinuation { (answer: CheckedContinuation<Answer, Never>) in
                let timeout = Task { @MainActor [weak self] in
                    guard (try? await Task.sleep(for: Self.answerTimeout)) != nil else { return }
                    self?.finishMessage(id, with: ["closed": true])
                }
                messages[id] = Message(target: target, registry: call.registry, answer: answer, timeout: timeout)
                events.emit("runtime", "onMessageExternal", args: [message, sender, id], to: [target])
            }
            return answer.value

        case "runtime.answerExternal":
            guard let id = call.string("messageId"), let message = messages[id], message.target == call.extensionId else { return nil }
            if let response = call.payload["response"] {
                finishMessage(id, with: ["response": response])
            } else if call.bool("worker") || call.registry.context(for: call.extensionId)?.webExtension.hasBackgroundContent == false {
                // The worker's word is final; a page's only when there is no worker.
                finishMessage(id, with: ["closed": true])
            }
            return nil

        case "runtime.connectExternal":
            guard let target = call.string("id"), let sender = sender(of: call, reaching: target, event: "onConnectExternal") else {
                return BridgeError(Self.noReceiver)
            }
            nextId += 1
            let id = String(nextId)
            let targetWorkerListens = events.reportedListeners(of: target)?.contains("runtime.onConnectExternal") ?? true
            ports[id] = Port(
                opener: call.extensionId, target: target, openerChannel: call.int("pageChannel"), targetWorkerListens: targetWorkerListens,
                targetPagesHeard: events.pageListens(target, to: "runtime.onConnectExternal"), registry: call.registry
            )
            // Both ends hear the port's messages from now on, before their contexts report it. An end whose worker
            // reported nothing yet already hears every event, and reporting for it would narrow that to these two.
            for end in [call.extensionId, target] where events.reportedListeners(of: end) != nil {
                events.listen(["runtime.portMessage", "runtime.portDisconnect"], extensionId: end)
            }
            events.emit("runtime", "onConnectExternal", args: [["portId": id, "name": call.string("name") ?? "", "sender": sender]], to: [target])
            return id

        case "runtime.portAccept":
            if let id = call.string("portId"), ports[id]?.target == call.extensionId, let channel = call.int("pageChannel") {
                ports[id]?.targetChannels.insert(channel)
            }
            return nil

        case "runtime.portDecline":
            // The worker had no listener: the port is left to the pages that heard it or, as in Chrome, fails.
            guard let id = call.string("portId"), let port = ports[id], port.target == call.extensionId, call.int("pageChannel") == nil else {
                return nil
            }
            ports[id]?.targetWorkerListens = false
            if !port.targetPagesHeard {
                disconnect(id, notifying: port.opener, registry: call.registry, error: Self.noReceiver)
            }
            return nil

        case "runtime.portPost", "runtime.portDisconnect":
            guard let id = call.string("portId"), let port = ports[id], let other = port.other(than: call.extensionId) else {
                return BridgeError("Attempting to use a disconnected port object")
            }
            if call.action == "runtime.portPost" {
                events.emit("runtime", "portMessage", args: [id, call.payload["message"] ?? NSNull()], to: [other])
            } else {
                disconnect(id, notifying: other, registry: call.registry)
            }
            return nil

        default:
            return await call.registry.updater.requestUpdateCheck(extensionId: call.extensionId)
        }
    }

    /// Chrome's `MessageSender` of the caller, nil when `target` is not loaded in the caller's profile, its
    /// `externally_connectable.ids` leaves the caller out (absent, every extension may connect), or neither its worker
    /// nor an open page listens to `event`.
    private func sender(of call: GapCall, reaching target: String, event: String) -> [String: Any]? {
        let registry = call.registry
        guard target != call.extensionId, let context = registry.context(for: target), let source = call.context else { return nil }
        if let connectable = context.webExtension.manifest["externally_connectable"] as? [String: Any] {
            let ids = connectable["ids"] as? [String] ?? []
            guard ids.contains("*") || ids.contains(call.extensionId) else { return nil }
        }
        guard !registry.gapEvents.listeners(among: [target], namespace: "runtime", event: event).isEmpty else { return nil }
        let base = source.baseURL.absoluteString
        let origin = String(base.dropLast(base.hasSuffix("/") ? 1 : 0))
        // A content script's frame, url and origin are its worker's word, as a page's tab is; a page's url must be its own extension's.
        let frameId = call.int("frameId")
        var sender: [String: Any] = [
            "id": call.extensionId,
            "url": call.string("url").flatMap { frameId != nil || $0.hasPrefix(base) ? $0 : nil } ?? base,
            "origin": frameId == nil ? origin : call.string("origin") ?? origin
        ]
        if let tab = call.payload["tab"] as? [String: Any] {
            sender["tab"] = tab
            sender["frameId"] = frameId ?? 0
        }
        return sender
    }

    private func finishMessage(_ id: String, with answer: [String: Any]) {
        guard let message = messages.removeValue(forKey: id) else { return }
        message.timeout.cancel()
        message.answer.resume(returning: Answer(value: answer))
    }

    /// `error` is the other end's `runtime.lastError` while its `onDisconnect` listeners run.
    private func disconnect(_ id: String, notifying extensionId: String, registry: ProfileExtensionRegistry?, error: String? = nil) {
        ports[id] = nil
        registry?.gapEvents.emit("runtime", "portDisconnect", args: error.map { [id, $0] } ?? [id], to: [extensionId])
    }

    /// A closed page's ends of ports go: the port disconnects for the other extension once nothing of this one holds it.
    private func pageDidClose(_ channel: Int, extensionId: String, events: ObjectIdentifier?) {
        for (id, port) in ports where port.registry.map({ ObjectIdentifier($0.gapEvents) }) == events {
            if port.opener == extensionId, port.openerChannel == channel {
                disconnect(id, notifying: port.target, registry: port.registry)
            } else if port.target == extensionId, ports[id]?.targetChannels.remove(channel) != nil,
                      ports[id]?.targetChannels.isEmpty == true, !port.targetWorkerListens {
                disconnect(id, notifying: port.opener, registry: port.registry)
            }
        }
    }

    /// An unloaded extension answers nothing more and its ports disconnect.
    private func extensionDidUnload(_ extensionId: String, registry: ProfileExtensionRegistry?) {
        for (id, message) in messages where message.target == extensionId && message.registry === registry {
            finishMessage(id, with: ["closed": true])
        }
        for (id, port) in ports where port.registry === registry {
            guard let other = port.other(than: extensionId) else { continue }
            disconnect(id, notifying: other, registry: registry)
        }
    }
}
