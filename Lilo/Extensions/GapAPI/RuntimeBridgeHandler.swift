import Foundation
import WebKit

/// The `chrome.runtime` calls WebKit lacks: `requestUpdateCheck`, against Lilo's update checker; whether the
/// worker listens to `runtime.onMessage`, which picks Chrome's error for a page's message nobody answers (a
/// worker that has not reported its listeners yet counts as listening); and messages and ports to another
/// extension of the profile, relayed to its `onMessageExternal` and `onConnectExternal`.
@MainActor
final class RuntimeBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "runtime.requestUpdateCheck", "runtime.workerListensToMessages",
        "runtime.sendExternal", "runtime.answerExternal", "runtime.connectExternal", "runtime.portPost", "runtime.portDisconnect"
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

    /// A port between two extensions of one profile.
    private struct Port {
        let opener: String
        let target: String
        weak var registry: ProfileExtensionRegistry?

        func other(than extensionId: String) -> String? {
            extensionId == opener ? target : extensionId == target ? opener : nil
        }
    }

    private var messages: [String: Message] = [:]
    private var ports: [String: Port] = [:]
    private var nextId = 0
    nonisolated(unsafe) private var unloadObserver: Any?

    init() {
        unloadObserver = NotificationCenter.default.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
            guard let extensionId = note.userInfo?["extensionId"] as? String else { return }
            let registry = note.object as? ProfileExtensionRegistry
            MainActor.assumeIsolated { self?.extensionDidUnload(extensionId, registry: registry) }
        }
    }

    deinit {
        unloadObserver.map { NotificationCenter.default.removeObserver($0) }
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
            ports[id] = Port(opener: call.extensionId, target: target, registry: call.registry)
            // Both ends hear the port's messages from now on, before their contexts report it. An end whose worker
            // reported nothing yet already hears every event, and reporting for it would narrow that to these two.
            for end in [call.extensionId, target] where events.reportedListeners(of: end) != nil {
                events.listen(["runtime.portMessage", "runtime.portDisconnect"], extensionId: end)
            }
            events.emit("runtime", "onConnectExternal", args: [["portId": id, "name": call.string("name") ?? "", "sender": sender]], to: [target])
            return id

        case "runtime.portPost", "runtime.portDisconnect":
            guard let id = call.string("portId"), let port = ports[id], let other = port.other(than: call.extensionId) else {
                return BridgeError("Attempting to use a disconnected port object")
            }
            if call.action == "runtime.portPost" {
                events.emit("runtime", "portMessage", args: [id, call.payload["message"] ?? NSNull()], to: [other])
            } else {
                ports[id] = nil
                events.emit("runtime", "portDisconnect", args: [id], to: [other])
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
        // The url is the caller's word: only one of its own extension's is taken.
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

    private func finishMessage(_ id: String, with answer: [String: Any]) {
        guard let message = messages.removeValue(forKey: id) else { return }
        message.timeout.cancel()
        message.answer.resume(returning: Answer(value: answer))
    }

    /// An unloaded extension answers nothing more and its ports disconnect.
    private func extensionDidUnload(_ extensionId: String, registry: ProfileExtensionRegistry?) {
        for (id, message) in messages where message.target == extensionId && message.registry === registry {
            finishMessage(id, with: ["closed": true])
        }
        for (id, port) in ports where port.registry === registry {
            guard let other = port.other(than: extensionId) else { continue }
            ports[id] = nil
            registry?.gapEvents.emit("runtime", "portDisconnect", args: [id], to: [other])
        }
    }
}
