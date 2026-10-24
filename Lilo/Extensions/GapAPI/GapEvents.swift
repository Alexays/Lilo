import WebKit

/// One event Lilo pushes for an API WebKit lacks, addressed to one extension. `args` is spread into
/// the JS `ChromeEvent.dispatch(...args)`, so it mirrors Chrome's argument list.
/// `@unchecked Sendable`: every field is `let` and `args` holds immutable JSON values built on the main actor.
struct GapEventEnvelope: @unchecked Sendable {
    let seq: Int
    let namespace: String
    let event: String
    let args: [Any]

    /// The message ipc.ts fires the named event for, in pages and workers alike.
    var dictionary: [String: Any] {
        ["seq": seq, "namespace": namespace, "event": event, "args": args]
    }
}

/// Lilo's one native port per extension page or worker, carrying gap calls and pushed events; events for a worker without a channel
/// wait here and wake it. An idle worker asks to close its channel so WebKit can unload it; page pushes batch per main-actor turn.
@MainActor
final class GapEvents {
    enum WorkerChannel {
        case open
        /// Closed at the worker's request: it is still running, until WebKit unloads it.
        case idle
        /// The worker stopped.
        case lost
        /// The extension unloads, and its worker with it.
        case unloaded
    }

    private struct Worker {
        var port: WKWebExtension.MessagePort?
        var instance: String?
        /// Oldest first, removed once the worker received them; kept while it is stopped.
        var undelivered: [GapEventEnvelope] = []
        /// The last event handed to `port`; the rest go out on the next delivery.
        var sentThrough = 0
        var nextSeq = 0

        /// Queues the event under the next sequence number, dropping the oldest past `undeliveredCap`.
        mutating func enqueue(_ namespace: String, _ event: String, args: [Any]) -> GapEventEnvelope {
            nextSeq += 1
            let envelope = GapEventEnvelope(seq: nextSeq, namespace: namespace, event: event, args: args)
            undelivered.append(envelope)
            if undelivered.count > GapEvents.undeliveredCap {
                undelivered.removeFirst(undelivered.count - GapEvents.undeliveredCap)
            }
            return envelope
        }
    }

    /// Past this many undelivered events the oldest go, so a chatty producer under a long-dead worker
    /// cannot grow memory without bound.
    private nonisolated static let undeliveredCap = 256

    private var workers: [String: Worker] = [:]
    /// "namespace.event" names each extension's pages and worker listen to, kept across idle unloads
    /// so a stopped worker still wakes for them.
    private var listeners: [String: Set<String>] = [:]
    /// Extensions whose worker reported its listeners, this launch or, restored, an earlier one. Until then the extension hears
    /// every event: its worker has not said what it listens to.
    private var workerReported: Set<String> = []
    /// The channels of the extension's open pages.
    private var pagePorts: [String: [WKWebExtension.MessagePort]] = [:]
    private var pendingPagePushes: [String: [[String: Any]]] = [:]
    private var pagePushScheduled = false

    private let wake: (String) -> Void
    private let workerChannel: (String, WorkerChannel) -> Void
    /// Answers a gap call from a page or the worker, as (result, error).
    private let route: @MainActor (_ namespace: String, _ method: String, _ params: [String: Any], _ extensionId: String, _ fromWorker: Bool) async -> (Any?, String?)

    init(
        wake: @escaping (String) -> Void,
        workerChannel: @escaping (String, WorkerChannel) -> Void,
        route: @escaping @MainActor (String, String, [String: Any], String, Bool) async -> (Any?, String?)
    ) {
        self.wake = wake
        self.workerChannel = workerChannel
        self.route = route
    }

    // MARK: - Listeners

    /// Records events a page or the worker of the extension listens to; the worker's own report
    /// turns on filtering for it. True when that changed what the extension is woken for.
    @discardableResult
    func listen(_ events: [String], extensionId: String, fromWorker: Bool) -> Bool {
        let count = listeners[extensionId]?.count ?? 0
        listeners[extensionId, default: []].formUnion(events)
        let reported = fromWorker && workerReported.insert(extensionId).inserted
        return reported || listeners[extensionId]?.count != count
    }

    /// The events the extension's worker reported listening to, nil until it reported.
    func reportedListeners(of extensionId: String) -> Set<String>? {
        workerReported.contains(extensionId) ? listeners[extensionId] ?? [] : nil
    }

    /// The extensions of `ids` that may hear the event.
    func listeners(among ids: [String], namespace: String, event: String) -> [String] {
        let name = "\(namespace).\(event)"
        return ids.filter { !workerReported.contains($0) || listeners[$0]?.contains(name) == true }
    }

    // MARK: - Events

    /// Sends the event to each listening extension's worker, waking it if stopped unless `wakes` is
    /// false, and pushes it to the extension's open pages at the end of the turn.
    func emit(_ namespace: String, _ event: String, args: [Any], to ids: [String], wakes: Bool = true) {
        for id in listeners(among: ids, namespace: namespace, event: event) {
            // Mutated in place: a copy of the worker would copy its whole undelivered queue.
            let envelope = workers[id, default: Worker()].enqueue(namespace, event, args: args)
            if workers[id]?.port != nil { deliver(to: id) } else if wakes { wake(id) }
            if pagePorts[id]?.isEmpty == false { pendingPagePushes[id, default: []].append(envelope.dictionary) }
        }
        guard !pagePushScheduled, !pendingPagePushes.isEmpty else { return }
        pagePushScheduled = true
        Task { @MainActor [weak self] in self?.pushToPages() }
    }

    /// Events the extension's worker has not received yet.
    func undelivered(to extensionId: String) -> [GapEventEnvelope] {
        workers[extensionId]?.undelivered ?? []
    }

    /// An unloaded extension's listeners; `purge` also drops what its worker had not received.
    func forget(_ extensionId: String, purge: Bool) {
        // The unloaded worker is gone: what comes next waits for the worker of the next load.
        detach(extensionId, .unloaded)
        listeners[extensionId] = nil
        workerReported.remove(extensionId)
        pagePorts[extensionId] = nil
        pendingPagePushes[extensionId] = nil
        if purge { workers[extensionId] = nil }
    }

    private func pushToPages() {
        pagePushScheduled = false
        let pushes = pendingPagePushes
        pendingPagePushes = [:]
        for (id, envelopes) in pushes {
            for port in pagePorts[id] ?? [] {
                port.sendMessage(["events": envelopes]) { _ in }
            }
        }
    }

    // MARK: - Ports

    /// A page or the worker opened its channel. Its first message says which; a restarted worker's
    /// port replaces the previous one. The worker's events go out once that message proves the port
    /// connected (WebKit drops what is sent before); the worker holds them until its top-level code has
    /// registered its listeners (ipc.ts `workerReady`).
    func attach(_ port: WKWebExtension.MessagePort, extensionId: String) {
        port.messageHandler = { [weak self, weak port] message, _ in
            guard let port, let message = message as? [String: Any] else { return }
            Task { @MainActor in
                guard let self else { return }
                if let role = message["role"] as? String {
                    self.adopt(port, asWorker: role == "worker", instance: message["instance"] as? String, extensionId: extensionId)
                } else if message["idle"] != nil {
                    self.close(port, extensionId: extensionId)
                } else {
                    await self.answer(message, on: port, extensionId: extensionId)
                }
            }
        }
        port.disconnectHandler = { [weak self, weak port] _ in
            Task { @MainActor in
                guard let self, let port else { return }
                if self.workers[extensionId]?.port === port {
                    self.detach(extensionId, .lost)
                } else {
                    self.pagePorts[extensionId]?.removeAll { $0 === port }
                }
            }
        }
    }

    private func adopt(_ port: WKWebExtension.MessagePort, asWorker: Bool, instance: String?, extensionId: String) {
        guard asWorker else {
            pagePorts[extensionId, default: []].append(port)
            return
        }
        workers[extensionId, default: Worker()].port = port
        workers[extensionId]?.instance = instance
        workers[extensionId]?.sentThrough = 0
        workerChannel(extensionId, .open)
        deliver(to: extensionId)
    }

    /// The worker heard nothing for a while and asked for its port to go. What it was sent and has not
    /// confirmed goes out again on its next port, which it opens when woken for it (ipc.ts drops repeats).
    private func close(_ port: WKWebExtension.MessagePort, extensionId: String) {
        port.disconnect()
        guard workers[extensionId]?.port === port else { return }
        detach(extensionId, .idle)
        if workers[extensionId]?.undelivered.isEmpty == false { wake(extensionId) }
    }

    func isConnected(_ extensionId: String) -> Bool {
        workers[extensionId]?.port != nil
    }

    /// The running worker's own id, which it sends on each channel it opens: a worker that reconnects
    /// after an idle close keeps it, the next worker has another.
    func workerInstance(of extensionId: String) -> String? {
        workers[extensionId]?.instance
    }

    private func detach(_ extensionId: String, _ channel: WorkerChannel) {
        guard workers[extensionId]?.port != nil else { return }
        workers[extensionId]?.port = nil
        workers[extensionId]?.sentThrough = 0
        workerChannel(extensionId, channel)
    }

    private func deliver(to extensionId: String) {
        guard let worker = workers[extensionId], let port = worker.port else { return }
        let unsent = worker.undelivered.filter { $0.seq > worker.sentThrough }
        guard let last = unsent.last else { return }
        workers[extensionId]?.sentThrough = last.seq
        for envelope in unsent {
            port.sendMessage(envelope.dictionary) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if error == nil {
                        self.workers[extensionId]?.undelivered.removeAll { $0.seq == envelope.seq }
                    } else if self.workers[extensionId]?.port === port {
                        // The worker is gone: everything not received waits for its next start.
                        self.detach(extensionId, .lost)
                    }
                }
            }
        }
    }

    private func answer(_ call: [String: Any], on port: WKWebExtension.MessagePort, extensionId: String) async {
        guard let id = call["id"], let namespace = call["namespace"] as? String, let method = call["method"] as? String else { return }
        let fromWorker = workers[extensionId]?.port === port
        let (result, error) = await route(namespace, method, call["params"] as? [String: Any] ?? [:], extensionId, fromWorker)
        let reply: [String: Any] = error.map { ["reply": id, "error": $0] } ?? ["reply": id, "result": result ?? NSNull()]
        port.sendMessage(reply) { _ in }
    }
}
