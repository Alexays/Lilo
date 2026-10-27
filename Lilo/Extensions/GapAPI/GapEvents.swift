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
/// wait here and wake it. An idle worker asks to close its channel so WebKit can unload it; pushes batch per main-actor turn.
///
/// WebKit keys a context's ports by a number each web process counts on its own (WEBKIT-GAPS 89): two contexts' channels can
/// share one, and then both reach the first port of that number. Each context names itself with a tag in its first message and
/// in the high bits of its call ids, and Lilo stamps what it sends with the tag of the port's context: a context that finds
/// its channel taken moves to a new one (ipc.ts).
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

        mutating func envelope(_ namespace: String, _ event: String, args: [Any]) -> GapEventEnvelope {
            nextSeq += 1
            return GapEventEnvelope(seq: nextSeq, namespace: namespace, event: event, args: args)
        }

        /// Queues the event, dropping the oldest past `undeliveredCap` for a stopped worker: a connected one takes them as
        /// they come, a burst of port messages included.
        mutating func enqueue(_ envelope: GapEventEnvelope) {
            undelivered.append(envelope)
            if port == nil, undelivered.count > GapEvents.undeliveredCap {
                undelivered.removeFirst(undelivered.count - GapEvents.undeliveredCap)
            }
        }
    }

    private struct Page {
        let port: WKWebExtension.MessagePort
        let channel: Int
        /// "namespace.event" names the page listens to: it hears only those.
        var listeners: Set<String> = []
        var pending: [[String: Any]] = []
    }

    /// Past this many undelivered events for a stopped worker the oldest go, so a chatty producer under a long-dead worker
    /// cannot grow memory without bound.
    private nonisolated static let undeliveredCap = 256
    /// The tag of the context a message is for, which ipc.ts checks first.
    private nonisolated static let channelKey = "liloChannel"

    private var workers: [String: Worker] = [:]
    /// "namespace.event" names each extension's worker listens to, kept across idle unloads so a
    /// stopped worker still wakes for them.
    private var workerListeners: [String: Set<String>] = [:]
    /// Extensions whose worker reported its listeners, this launch or, restored, an earlier one. Until then the worker hears
    /// every event: it has not said what it listens to.
    private var workerReported: Set<String> = []
    /// The channels of the extension's open pages.
    private var pages: [String: [Page]] = [:]
    private var nextPageChannel = 0
    /// The tag of the context each adopted port belongs to, by port.
    private var owners: [ObjectIdentifier: Int64] = [:]
    /// Ports attached and not adopted yet, by extension.
    private var opening: [String: [WKWebExtension.MessagePort]] = [:]
    /// Ports WebKit numbered as an open one of their extension, by extension. WebKit never registers them; releasing one
    /// unregisters whatever port holds its number and, once that is gone, disconnects the pages still holding it.
    private var twins: [String: [WKWebExtension.MessagePort]] = [:]
    /// Extensions with events for their connected worker or their pages, sent at the end of the turn.
    private var unflushed: Set<String> = []
    private var flushScheduled = false

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

    /// Records events the extension's worker listens to, or, `removed`, no longer listens to; its first
    /// report turns on filtering. True when that changed what the worker is woken for.
    @discardableResult
    func listen(_ events: [String], extensionId: String, removed: Bool = false) -> Bool {
        let count = workerListeners[extensionId]?.count ?? 0
        if removed {
            workerListeners[extensionId]?.subtract(events)
        } else {
            workerListeners[extensionId, default: []].formUnion(events)
        }
        let reported = !removed && workerReported.insert(extensionId).inserted
        return reported || workerListeners[extensionId]?.count ?? 0 != count
    }

    /// The events the extension's worker reported listening to, nil until it reported.
    func reportedListeners(of extensionId: String) -> Set<String>? {
        workerReported.contains(extensionId) ? workerListeners[extensionId] ?? [] : nil
    }

    /// The extensions of `ids` whose worker or an open page may hear the event.
    func listeners(among ids: [String], namespace: String, event: String) -> [String] {
        let name = "\(namespace).\(event)"
        return ids.filter { id in
            !workerReported.contains(id) || workerListeners[id]?.contains(name) == true || pageListens(id, to: name)
        }
    }

    /// Whether one of the extension's open pages listens to `name`, a "namespace.event".
    func pageListens(_ extensionId: String, to name: String) -> Bool {
        pages[extensionId]?.contains { $0.listeners.contains(name) } == true
    }

    /// The extension's contexts that reported listening to `name`: nil for its worker, else a page's `pageChannel`.
    func contexts(of extensionId: String, listeningTo name: String) -> [Int?] {
        var contexts: [Int?] = workerListeners[extensionId]?.contains(name) == true ? [nil] : []
        for page in pages[extensionId] ?? [] where page.listeners.contains(name) { contexts.append(page.channel) }
        return contexts
    }

    // MARK: - Events

    /// Sends the event to each extension's worker that listens, waking it if stopped unless `wakes` is
    /// false, and to its open pages that listen, at the end of the turn.
    func emit(_ namespace: String, _ event: String, args: [Any], to ids: [String], wakes: Bool = true) {
        let name = "\(namespace).\(event)"
        for id in ids {
            let toWorker = !workerReported.contains(id) || workerListeners[id]?.contains(name) == true
            let toPages = pageListens(id, to: name)
            guard toWorker || toPages else { continue }
            // Mutated in place: a copy of the worker would copy its whole undelivered queue.
            let envelope = workers[id, default: Worker()].envelope(namespace, event, args: args)
            if toWorker {
                workers[id]?.enqueue(envelope)
                if workers[id]?.port != nil { unflushed.insert(id) } else if wakes { wake(id) }
            }
            if toPages, let indices = pages[id]?.indices {
                let message = envelope.dictionary
                for index in indices where pages[id]?[index].listeners.contains(name) == true {
                    pages[id]?[index].pending.append(message)
                }
                unflushed.insert(id)
            }
        }
        guard !flushScheduled, !unflushed.isEmpty else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in self?.flush() }
    }

    /// Sends the event now to some of the extension's contexts whatever they listen to: nil in `contexts` for its worker, waking
    /// it if stopped unless `wakes` is false, else a page's channel. Their earlier events go first.
    func emit(_ namespace: String, _ event: String, args: [Any], to extensionId: String, contexts: Set<Int?>, wakes: Bool = true) {
        let envelope = workers[extensionId, default: Worker()].envelope(namespace, event, args: args)
        if contexts.contains(nil) {
            workers[extensionId]?.enqueue(envelope)
            if workers[extensionId]?.port != nil { unflushed.insert(extensionId) } else if wakes { wake(extensionId) }
        }
        if contexts.contains(where: { $0 != nil }), let indices = pages[extensionId]?.indices {
            let message = envelope.dictionary
            for index in indices where contexts.contains(pages[extensionId]?[index].channel) {
                pages[extensionId]?[index].pending.append(message)
            }
        }
        // A port's messages come batched: waiting for the end of the turn would only add a hop to each round trip.
        send(to: extensionId)
    }

    /// Sends `message` now over the extension's open channels, its running worker's and its pages': a stopped worker misses it.
    func send(_ message: [String: Any], toOpenChannelsOf extensionId: String) {
        var message = message
        if let port = workers[extensionId]?.port {
            message[Self.channelKey] = owners[ObjectIdentifier(port)]
            port.sendMessage(message) { _ in }
        }
        for page in pages[extensionId] ?? [] {
            message[Self.channelKey] = owners[ObjectIdentifier(page.port)]
            page.port.sendMessage(message) { _ in }
        }
    }

    /// Events the extension's worker has not received yet.
    func undelivered(to extensionId: String) -> [GapEventEnvelope] {
        workers[extensionId]?.undelivered ?? []
    }

    /// An unloaded extension's listeners; `purge` also drops what its worker had not received.
    func forget(_ extensionId: String, purge: Bool) {
        // The unloaded worker is gone: what comes next waits for the worker of the next load.
        detach(extensionId, .unloaded)
        workerListeners[extensionId] = nil
        workerReported.remove(extensionId)
        pages.removeValue(forKey: extensionId)?.forEach { owners[ObjectIdentifier($0.port)] = nil }
        opening[extensionId] = nil
        twins[extensionId] = nil
        if purge { workers[extensionId] = nil }
    }

    private func flush() {
        flushScheduled = false
        let ids = unflushed
        unflushed = []
        ids.forEach(send(to:))
    }

    /// Sends what the extension's connected worker and its pages have pending.
    private func send(to extensionId: String) {
        deliver(to: extensionId)
        for index in pages[extensionId]?.indices ?? 0..<0 {
            guard let page = pages[extensionId]?[index], !page.pending.isEmpty else { continue }
            pages[extensionId]?[index].pending = []
            page.port.sendMessage(["events": page.pending, Self.channelKey: owners[ObjectIdentifier(page.port)] ?? 0]) { _ in }
        }
    }

    // MARK: - Ports

    /// A page or the worker opened its channel. Its first message says which; a restarted worker's
    /// port replaces the previous one. The worker's events go out once that message proves the port
    /// connected (WebKit drops what is sent before); the worker holds them until its top-level code has
    /// registered its listeners (ipc.ts `workerReady`).
    func attach(_ port: WKWebExtension.MessagePort, extensionId: String) {
        // `isEqual` compares the extension, host and number.
        if workers[extensionId]?.port?.isEqual(port) == true || pages[extensionId]?.contains(where: { $0.port.isEqual(port) }) == true
            || opening[extensionId]?.contains(where: { $0.isEqual(port) }) == true {
            twins[extensionId, default: []].append(port)
            return
        }
        opening[extensionId, default: []].append(port)
        port.messageHandler = { [weak self, weak port] message, _ in
            guard let port, let message = message as? [String: Any] else { return }
            // A hop, not assumeIsolated: a handler WebKit calls off the main thread would trap.
            Task { @MainActor in
                guard let self else { return }
                let owner = self.owners[ObjectIdentifier(port)]
                if let role = message["role"] as? String {
                    let tag = (message["tag"] as? NSNumber)?.int64Value ?? 0
                    if owner == nil {
                        self.adopt(port, asWorker: role == "worker", instance: message["instance"] as? String, tag: tag, extensionId: extensionId)
                    } else if owner != tag {
                        // Another context's channel drew this port's number: it opens another one.
                        try? await port.sendMessage(["collided": true, Self.channelKey: tag])
                    }
                    return
                }
                // Another context's call, which it sends again on its next channel.
                if let id = (message["id"] as? NSNumber)?.int64Value, let owner, id >> 32 != owner { return }
                if message["idle"] != nil {
                    self.close(port, extensionId: extensionId)
                    return
                }
                // A page's listeners are its own: recorded before any later message on its port is answered.
                if message["namespace"] as? String == "events", let index = self.pages[extensionId]?.firstIndex(where: { $0.port === port }) {
                    let events = (message["params"] as? [String: Any])?["events"] as? [String] ?? []
                    switch message["method"] as? String {
                    case "listen": self.pages[extensionId]?[index].listeners.formUnion(events)
                    case "unlisten": self.pages[extensionId]?[index].listeners.subtract(events)
                    default: break
                    }
                }
                await self.answer(message, on: port, extensionId: extensionId)
            }
        }
        port.disconnectHandler = { [weak self, weak port] _ in
            Task { @MainActor in
                guard let self, let port else { return }
                self.opening[extensionId]?.removeAll { $0 === port }
                self.owners[ObjectIdentifier(port)] = nil
                if self.workers[extensionId]?.port === port {
                    self.detach(extensionId, .lost)
                } else if let index = self.pages[extensionId]?.firstIndex(where: { $0.port === port }) {
                    let channel = self.pages[extensionId]?.remove(at: index).channel
                    NotificationCenter.default.post(name: .extensionPageChannelDidClose, object: self, userInfo: ["extensionId": extensionId, "channel": channel as Any])
                }
            }
        }
    }

    private func adopt(_ port: WKWebExtension.MessagePort, asWorker: Bool, instance: String?, tag: Int64, extensionId: String) {
        opening[extensionId]?.removeAll { $0 === port }
        owners[ObjectIdentifier(port)] = tag
        guard asWorker else {
            nextPageChannel += 1
            pages[extensionId, default: []].append(Page(port: port, channel: nextPageChannel))
            return
        }
        if let previous = workers[extensionId]?.port { owners[ObjectIdentifier(previous)] = nil }
        let restarted = workers[extensionId]?.instance != instance
        workers[extensionId, default: Worker()].port = port
        workers[extensionId]?.instance = instance
        workers[extensionId]?.sentThrough = 0
        if restarted { NotificationCenter.default.post(name: .extensionWorkerDidStart, object: self, userInfo: ["extensionId": extensionId]) }
        workerChannel(extensionId, .open)
        deliver(to: extensionId)
    }

    /// The worker heard nothing for a while and asked for its port to go. What it was sent and has not
    /// confirmed goes out again on its next port, which it opens when woken for it (ipc.ts drops repeats).
    private func close(_ port: WKWebExtension.MessagePort, extensionId: String) {
        port.disconnect()
        owners[ObjectIdentifier(port)] = nil
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
        guard let port = workers[extensionId]?.port else { return }
        owners[ObjectIdentifier(port)] = nil
        workers[extensionId]?.port = nil
        workers[extensionId]?.sentThrough = 0
        workerChannel(extensionId, channel)
        NotificationCenter.default.post(name: .extensionWorkerDidStop, object: self, userInfo: [
            "extensionId": extensionId, "instance": workers[extensionId]?.instance as Any
        ])
    }

    /// Sends what the worker has not been sent in one message; its delivery confirms all of it.
    private func deliver(to extensionId: String) {
        guard let worker = workers[extensionId], let port = worker.port,
              let first = worker.undelivered.firstIndex(where: { $0.seq > worker.sentThrough }),
              let last = worker.undelivered.last?.seq else { return }
        workers[extensionId]?.sentThrough = last
        port.sendMessage(["events": worker.undelivered[first...].map(\.dictionary), Self.channelKey: owners[ObjectIdentifier(port)] ?? 0]) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error == nil {
                    self.workers[extensionId]?.undelivered.removeAll { $0.seq <= last }
                } else if self.workers[extensionId]?.port === port {
                    // The worker is gone: everything not received waits for its next start.
                    self.detach(extensionId, .lost)
                }
            }
        }
    }

    private func answer(_ call: [String: Any], on port: WKWebExtension.MessagePort, extensionId: String) async {
        guard let id = call["id"], let namespace = call["namespace"] as? String, let method = call["method"] as? String else { return }
        let fromWorker = workers[extensionId]?.port === port
        var params = call["params"] as? [String: Any] ?? [:]
        // Only Lilo names a page's channel: what the page holds (a port) goes with it.
        params["pageChannel"] = fromWorker ? nil : pages[extensionId]?.first { $0.port === port }?.channel
        let tag = owners[ObjectIdentifier(port)] ?? 0
        let (result, error) = await route(namespace, method, params, extensionId, fromWorker)
        let reply: [String: Any] = error.map { ["reply": id, "error": $0, Self.channelKey: tag] } ?? ["reply": id, "result": result ?? NSNull(), Self.channelKey: tag]
        try? await port.sendMessage(reply)
    }
}

extension Notification.Name {
    /// Object: the `GapEvents`. userInfo: "extensionId" and "channel" (Int), the `pageChannel` of the page's calls.
    static let extensionPageChannelDidClose = Notification.Name("fr.arouillard.lilo.extensionPageChannelDidClose")
    /// Object: the `GapEvents`. userInfo: "extensionId". A new worker instance connected: what the previous one held is gone.
    static let extensionWorkerDidStart = Notification.Name("fr.arouillard.lilo.extensionWorkerDidStart")
    /// Object: the `GapEvents`. userInfo: "extensionId" and "instance" (String). The worker stopped, went idle (WebKit then
    /// unloads it) or unloads with its extension.
    static let extensionWorkerDidStop = Notification.Name("fr.arouillard.lilo.extensionWorkerDidStop")
}
