import Foundation
import WebKit

/// The `chrome.runtime` calls WebKit lacks: `requestUpdateCheck`, against Lilo's update checker; whether the
/// worker listens to `runtime.onMessage`, which picks Chrome's error for a page's message nobody answers (a
/// worker that has not reported its listeners yet counts as listening); and messages and ports to another
/// extension of the profile, relayed to its `onMessageExternal` and `onConnectExternal`, from its pages, its worker
/// and, through the worker, its content scripts. Ports between the extension's own pages and worker go through Lilo too:
/// WebKit drops one when a process answers before the one that listens (WEBKIT-GAPS 60).
@MainActor
final class RuntimeBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "runtime.requestUpdateCheck", "runtime.workerListensToMessages",
        "runtime.sendExternal", "runtime.answerExternal", "runtime.connectExternal", "runtime.connect", "runtime.portAccept", "runtime.portDecline",
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

    /// A port between contexts of one extension, as Chrome's: it reaches every other context listening to `onConnect`, the
    /// opener's messages go to each of them and theirs to the opener, and it fails only when none takes it. A context is nil
    /// for the worker, else a page's channel.
    private struct LocalPort {
        let id: String
        let extensionId: String
        let opener: Int?
        /// The contexts it reached that have not declined or disconnected it.
        var receivers: Set<Int?>
        /// Whether one of them took it: once its receivers are gone it disconnects without an error.
        var taken = false
        /// The worker that holds an end of it, which takes it along when it stops; nil while no running worker took it.
        var workerInstance: String?
        weak var registry: ProfileExtensionRegistry?
    }

    private var messages: [String: Message] = [:]
    private var ports: [String: Port] = [:]
    /// By the opener's id for the port, which it posts on at once, and its extension.
    private var localPorts: [String: LocalPort] = [:]
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
        // As in Chrome, a stopped worker's ports disconnect: an idle one is about to be unloaded, and a new one holds none.
        for name in [Notification.Name.extensionWorkerDidStop, .extensionWorkerDidStart] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let extensionId = note.userInfo?["extensionId"] as? String else { return }
                let events = (note.object as AnyObject?).map(ObjectIdentifier.init)
                let stopped = name == .extensionWorkerDidStop ? note.userInfo?["instance"] as? String : nil
                MainActor.assumeIsolated { self?.workerDidChange(extensionId, events: events, stopped: stopped) }
            })
        }
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
                events.listen(["runtime.portMessages", "runtime.portDisconnect"], extensionId: end)
            }
            events.emit("runtime", "onConnectExternal", args: [["portId": id, "name": call.string("name") ?? "", "sender": sender]], to: [target])
            return id

        case "runtime.connect":
            guard let portId = call.string("portId") else { return nil }
            let opener = call.int("pageChannel")
            var receivers = Set(events.contexts(of: call.extensionId, listeningTo: "runtime.onConnect"))
            // A worker that has not reported its listeners hears every port: it declines one it does not take.
            if events.reportedListeners(of: call.extensionId) == nil, call.context?.webExtension.hasBackgroundContent == true {
                receivers.insert(nil)
            }
            receivers.remove(opener)
            let key = Self.key(portId, call.extensionId, call.registry)
            guard !receivers.isEmpty, let sender = localSender(of: call) else {
                events.emit("runtime", "portDisconnect", args: [portId, Self.noReceiver], to: call.extensionId, contexts: [opener])
                return nil
            }
            localPorts[key] = LocalPort(
                id: portId, extensionId: call.extensionId, opener: opener, receivers: receivers,
                // The running worker's, which goes with its end; one that starts later gets the port as it accepts it.
                workerInstance: opener == nil || receivers.contains(nil) ? events.workerInstance(of: call.extensionId) : nil,
                registry: call.registry
            )
            events.emit("runtime", "onConnect", args: [["portId": portId, "name": call.string("name") ?? "", "sender": sender]],
                        to: call.extensionId, contexts: receivers)
            return nil

        case "runtime.portAccept" where localPorts[Self.key(call.string("portId"), call.extensionId, call.registry)] != nil:
            let key = Self.key(call.string("portId"), call.extensionId, call.registry)
            let context = call.int("pageChannel")
            guard localPorts[key]?.receivers.contains(context) == true else { return nil }
            if context == nil {
                // A worker that stopped since took the port with it.
                let current = events.workerInstance(of: call.extensionId)
                guard call.string("instance").map({ $0 == current }) ?? true else {
                    leave(key, context: nil)
                    return nil
                }
                localPorts[key]?.workerInstance = current
            }
            localPorts[key]?.taken = true
            return nil

        case "runtime.portDecline" where localPorts[Self.key(call.string("portId"), call.extensionId, call.registry)] != nil:
            leave(Self.key(call.string("portId"), call.extensionId, call.registry), context: call.int("pageChannel"))
            return nil

        case "runtime.portPost" where localPorts[Self.key(call.string("portId"), call.extensionId, call.registry)] != nil,
             "runtime.portDisconnect" where localPorts[Self.key(call.string("portId"), call.extensionId, call.registry)] != nil:
            let key = Self.key(call.string("portId"), call.extensionId, call.registry)
            guard let port = localPorts[key] else { return nil }
            let context = call.int("pageChannel")
            if call.action == "runtime.portDisconnect" {
                leave(key, context: context)
            } else if context == port.opener {
                events.emit("runtime", "portMessages", args: [port.id, call.string("json") ?? "[]"], to: port.extensionId, contexts: port.receivers)
            } else if port.receivers.contains(context) {
                events.emit("runtime", "portMessages", args: [port.id, call.string("json") ?? "[]"], to: port.extensionId, contexts: [port.opener])
            } else {
                return BridgeError("Attempting to use a disconnected port object")
            }
            return nil

        case "runtime.portAccept":
            guard let id = call.string("portId") else { return nil }
            guard ports[id] != nil else {
                // The port went before this context took it (its opener, or the worker it was first sent to): its end here goes too.
                events.emit("runtime", "portDisconnect", args: [id], to: call.extensionId, contexts: [call.int("pageChannel")], wakes: false)
                return nil
            }
            if ports[id]?.target == call.extensionId, let channel = call.int("pageChannel") {
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
                events.emit("runtime", "portMessages", args: [id, call.string("json") ?? "[]"], to: [other])
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

    /// Chrome's `MessageSender` of a context of the extension: its id, its url, which a page's must be the extension's own,
    /// its origin, and a page's tab. Nil for a call from no loaded context.
    private func localSender(of call: GapCall) -> [String: Any]? {
        guard let context = call.context else { return nil }
        let base = context.baseURL.absoluteString
        var sender: [String: Any] = [
            "id": call.extensionId,
            "url": call.string("url").flatMap { $0.hasPrefix(base) ? $0 : nil } ?? base,
            "origin": String(base.dropLast(base.hasSuffix("/") ? 1 : 0))
        ]
        if let tab = call.payload["tab"] as? [String: Any] {
            sender["tab"] = tab
            sender["frameId"] = 0
        }
        return sender
    }

    private static func key(_ portId: String?, _ extensionId: String, _ registry: ProfileExtensionRegistry) -> String {
        "\(ObjectIdentifier(registry).hashValue) \(extensionId) \(portId ?? "")"
    }

    /// `context` lets go of the local port: the opener disconnects every receiver; the last receiver going disconnects the
    /// opener, with Chrome's error when none took it.
    private func leave(_ key: String, context: Int?) {
        guard let port = localPorts[key] else { return }
        let events = port.registry?.gapEvents
        if context == port.opener {
            localPorts[key] = nil
            events?.emit("runtime", "portDisconnect", args: [port.id], to: port.extensionId, contexts: port.receivers, wakes: false)
            return
        }
        guard localPorts[key]?.receivers.remove(context) != nil else { return }
        if context == nil { localPorts[key]?.workerInstance = nil }
        guard localPorts[key]?.receivers.isEmpty == true else { return }
        localPorts[key] = nil
        events?.emit("runtime", "portDisconnect", args: port.taken ? [port.id] : [port.id, Self.noReceiver], to: port.extensionId, contexts: [port.opener], wakes: false)
    }

    /// The worker stopped (`stopped`, its instance) or a new one started: the ends a previous worker took go with it.
    private func workerDidChange(_ extensionId: String, events: ObjectIdentifier?, stopped: String?) {
        for (key, port) in localPorts where port.extensionId == extensionId && port.registry.map({ ObjectIdentifier($0.gapEvents) }) == events {
            guard let instance = port.workerInstance, stopped == nil || instance == stopped else { continue }
            if stopped == nil, instance == port.registry?.gapEvents.workerInstance(of: extensionId) { continue }
            leave(key, context: nil)
        }
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
        for (key, port) in localPorts where port.extensionId == extensionId && port.registry.map({ ObjectIdentifier($0.gapEvents) }) == events {
            leave(key, context: channel)
        }
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
        for (key, port) in localPorts where port.extensionId == extensionId && port.registry === registry { localPorts[key] = nil }
    }
}
