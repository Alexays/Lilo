import Foundation
import Network
import dnssd

/// chrome.system.network and chrome.mdns. Each onServiceList filter reaches Lilo as the listener of its own event,
/// `mdns.onServiceList/<serviceType>`: a type is browsed while an extension holding mdns listens to it, its stopped
/// worker included as Chrome keeps lazy listeners, and nothing runs once none does.
@MainActor
final class LocalNetworkBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["system.network.getNetworkInterfaces", "mdns.forceDiscovery", "mdns.watch"]

    /// Chrome's mdns.MAX_SERVICE_INSTANCES_PER_EVENT.
    private static let maxServicesPerEvent = 2048
    private static let eventPrefix = "onServiceList/"

    /// One context listening to a service type: an extension's worker (nil) or page channel, in a profile.
    private struct Listener: Hashable {
        let registry: ObjectIdentifier
        let extensionId: String
        let context: Int?
    }

    fileprivate struct Service: Equatable {
        let hostPort: String
        let ipAddress: String
        let txt: [String]
    }

    /// A browsed service type and its instances, by instance name.
    private struct Browse {
        var browser: NWBrowser
        var metadata: [String: NWBrowser.Result.Metadata] = [:]
        var resolutions: [String: ServiceResolution] = [:]
        var services: [String: Service] = [:]
        var listeners: Set<Listener> = []
        /// Set by forceDiscovery: the next results are resolved again, and stand for every instance there is.
        var refreshing = false
    }

    private let registriesProvider: () -> [ProfileExtensionRegistry]
    private var browses: [String: Browse] = [:]
    /// Service types a page or worker said it listens to: GapEvents knows a page's listeners by name only.
    private var watchedTypes: Set<String> = []
    private var unsent: Set<String> = []
    nonisolated(unsafe) private var observers: [Any] = []

    init(registriesProvider: @escaping () -> [ProfileExtensionRegistry]) {
        self.registriesProvider = registriesProvider
        // A load restores a worker's listeners; a listener change, an unload or a closed page may start or stop a browse.
        observers = [Notification.Name.extensionRuntimeLoaded, .extensionGapListenersChanged, .extensionDidUnload, .extensionPageChannelDidClose].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        switch call.action {
        case "system.network.getNetworkInterfaces":
            return Self.networkInterfaces()
        case "mdns.watch":
            if let type = call.string("serviceType"), watchedTypes.insert(type).inserted { update() }
            return nil
        case "mdns.forceDiscovery":
            for type in browses.keys { restart(type) }
            return nil
        default:
            return nil
        }
    }

    // MARK: - system.network

    /// Chrome's list: each IPv4 and IPv6 address of the interfaces that are up, loopback aside.
    private static func networkInterfaces() -> [[String: Any]] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var interfaces: [[String: Any]] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }).map(\.pointee) {
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6, let text = numericHost(address), text != "0.0.0.0", text != "::" else { continue }
            interfaces.append(["name": String(cString: entry.ifa_name), "address": text, "prefixLength": prefixLength(entry.ifa_netmask, family: family)])
        }
        return interfaces
    }

    /// The address as Chrome prints it: a link-local one without its scope ("%en0").
    nonisolated fileprivate static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return text.split(separator: "%", maxSplits: 1).first.map(String.init)
    }

    /// The set bits of the netmask, read no further than its `sa_len`: the kernel truncates an IPv4 mask's sockaddr.
    private static func prefixLength(_ netmask: UnsafeMutablePointer<sockaddr>?, family: Int32) -> Int {
        guard let netmask else { return 0 }
        let (offset, length) = family == AF_INET
            ? (MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!, 4)
            : (MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!, 16)
        let available = max(0, min(length, Int(netmask.pointee.sa_len) - offset))
        let bytes = UnsafeRawPointer(netmask)
        return (0..<available).reduce(0) { $0 + bytes.load(fromByteOffset: offset + $1, as: UInt8.self).nonzeroBitCount }
    }

    // MARK: - mdns

    /// Browses the service types listened to and stops the others. A context that starts listening to a type is sent
    /// its current list, as Chrome does, without waking a stopped worker.
    private func update() {
        let listenerPrefix = "mdns.\(Self.eventPrefix)"
        var wanted: [String: Set<Listener>] = [:]
        for registry in registriesProvider() {
            let events = registry.gapEvents
            for id in registry.extensionIds(withPermission: "mdns") {
                let workerTypes = (events.reportedListeners(of: id) ?? []).compactMap { name in
                    name.hasPrefix(listenerPrefix) ? String(name.dropFirst(listenerPrefix.count)) : nil
                }
                for type in watchedTypes.union(workerTypes) {
                    for context in events.contexts(of: id, listeningTo: listenerPrefix + type) {
                        wanted[type, default: []].insert(Listener(registry: ObjectIdentifier(registry), extensionId: id, context: context))
                    }
                }
            }
        }
        for type in browses.keys where wanted[type] == nil { stop(type) }
        for (type, listeners) in wanted {
            if browses[type] == nil {
                guard let descriptor = Self.descriptor(type) else { continue }
                browses[type] = Browse(browser: NWBrowser(for: descriptor, using: NWParameters()))
                start(type)
            }
            guard let previous = browses[type]?.listeners else { continue }
            browses[type]?.listeners = listeners
            let added = Set(listeners.subtracting(previous).map(\.extensionId))
            if !added.isEmpty { send(type, to: added, wakes: false) }
        }
    }

    /// The Bonjour type of an onServiceList filter, "_ipp._tcp.local" for instance; nil for one never found.
    private static func descriptor(_ serviceType: String) -> NWBrowser.Descriptor? {
        let parts = serviceType.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count > 1, parts[0].hasPrefix("_"), ["_tcp", "_udp"].contains(parts[1]), parts[2] == "local" else { return nil }
        return .bonjourWithTXTRecord(type: "\(parts[0]).\(parts[1])", domain: "local.")
    }

    private func start(_ type: String) {
        guard let browser = browses[type]?.browser else { return }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.resultsChanged(results, type: type) }
        }
        browser.start(queue: .main)
    }

    private func stop(_ type: String) {
        guard let browse = browses.removeValue(forKey: type) else { return }
        browse.browser.cancel()
        browse.resolutions.values.forEach { $0.cancel() }
        unsent.remove(type)
    }

    /// A new query for the type, whose instances are all resolved again.
    private func restart(_ type: String) {
        guard let browse = browses[type] else { return }
        browse.browser.cancel()
        browse.resolutions.values.forEach { $0.cancel() }
        browses[type]?.resolutions = [:]
        browses[type]?.refreshing = true
        browses[type]?.browser = NWBrowser(for: browse.browser.descriptor, using: NWParameters())
        start(type)
    }

    /// Resolves the instances found or whose TXT record changed, and lists those gone no more. An instance seen on
    /// several interfaces is listed once.
    private func resultsChanged(_ results: Set<NWBrowser.Result>, type: String) {
        guard let known = browses[type]?.metadata, let refresh = browses[type]?.refreshing else { return }
        browses[type]?.refreshing = false
        var found: [String: NWBrowser.Result.Metadata] = [:]
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint { found[name] = result.metadata }
        }
        for name in known.keys where found[name] == nil {
            browses[type]?.metadata[name] = nil
            browses[type]?.resolutions.removeValue(forKey: name)?.cancel()
            if browses[type]?.services.removeValue(forKey: name) != nil { scheduleSend(type) }
        }
        let bonjourType = String(type.dropLast(".local".count))
        for (name, metadata) in found where refresh || known[name] != metadata {
            browses[type]?.metadata[name] = metadata
            browses[type]?.resolutions.removeValue(forKey: name)?.cancel()
            let resolution = ServiceResolution(name: name, type: bonjourType) { [weak self] service in
                self?.resolved(service, name: name, type: type)
            }
            if !resolution.isFinished { browses[type]?.resolutions[name] = resolution }
        }
    }

    private func resolved(_ service: Service?, name: String, type: String) {
        browses[type]?.resolutions[name] = nil
        // An instance that does not resolve stays out of the list, as in Chrome.
        guard let service, browses[type]?.services[name] != service else { return }
        browses[type]?.services[name] = service
        scheduleSend(type)
    }

    /// One list per type and main-actor turn: a burst of results reaches listeners once.
    private func scheduleSend(_ type: String) {
        guard unsent.insert(type).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self, self.unsent.remove(type) != nil else { return }
            self.send(type, to: nil, wakes: true)
        }
    }

    /// The type's list to the extensions of `ids`, or to every extension holding mdns that listens to it.
    private func send(_ type: String, to ids: Set<String>?, wakes: Bool) {
        guard let services = browses[type]?.services else { return }
        let list: [[String: Any]] = services.sorted { $0.key < $1.key }.prefix(Self.maxServicesPerEvent).map { name, service in
            ["serviceName": "\(name).\(type)", "serviceHostPort": service.hostPort, "ipAddress": service.ipAddress, "serviceData": service.txt]
        }
        for registry in registriesProvider() {
            let holders = registry.extensionIds(withPermission: "mdns").filter { ids?.contains($0) ?? true }
            registry.gapEvents.emit("mdns", Self.eventPrefix + type, args: [list], to: holders, wakes: wakes)
        }
    }
}

/// Resolves one service instance to its host, port and TXT strings, then to an address, IPv4 first as Chrome
/// picks it. dns_sd calls back on the main queue; an instance that does not resolve within 5 s ends as nil.
@MainActor
private final class ServiceResolution {
    private var ref: DNSServiceRef?
    private var hostPort = ""
    private var txt: [String] = []
    private var ipv6: String?
    private var timeout: Task<Void, Never>?
    private var done: ((LocalNetworkBridgeHandler.Service?) -> Void)?

    var isFinished: Bool { done == nil }

    init(name: String, type: String, done: @escaping (LocalNetworkBridgeHandler.Service?) -> Void) {
        self.done = done
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = DNSServiceResolve(&ref, 0, 0, name, type, "local.", { _, _, _, error, _, host, port, txtLength, txtRecord, context in
            guard let context else { return }
            let host = error == DNSServiceErrorType(kDNSServiceErr_NoError) ? host.map { String(cString: $0) } : nil
            let record = txtRecord.map { Array(UnsafeBufferPointer(start: $0, count: Int(txtLength))) } ?? []
            MainActor.assumeIsolated {
                Unmanaged<ServiceResolution>.fromOpaque(context).takeUnretainedValue().resolved(host: host, port: UInt16(bigEndian: port), txt: record)
            }
        }, context)
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            finish(nil)
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.finish(self.ipv6)
        }
    }

    /// Ends the resolution without a result.
    func cancel() {
        done = nil
        finish(nil)
    }

    private func resolved(host: String?, port: UInt16, txt record: [UInt8]) {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
        guard let host else { return finish(nil) }
        hostPort = "\(host.hasSuffix(".") ? String(host.dropLast()) : host):\(port)"
        // A TXT record is a run of strings, each after its length byte.
        var index = 0
        while index < record.count {
            let end = min(record.count, index + 1 + Int(record[index]))
            if end > index + 1, let text = String(bytes: record[(index + 1)..<end], encoding: .utf8) { txt.append(text) }
            index = end
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let status = DNSServiceGetAddrInfo(&ref, 0, 0, protocols, host, { _, _, _, error, _, address, _, context in
            guard let context, error == DNSServiceErrorType(kDNSServiceErr_NoError), let address,
                  let ip = LocalNetworkBridgeHandler.numericHost(address) else { return }
            let isIPv4 = Int32(address.pointee.sa_family) == AF_INET
            MainActor.assumeIsolated {
                Unmanaged<ServiceResolution>.fromOpaque(context).takeUnretainedValue().found(ip, isIPv4: isIPv4)
            }
        }, context)
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return finish(nil) }
        DNSServiceSetDispatchQueue(ref, .main)
    }

    /// An IPv6 address waits for an IPv4 one until the timeout.
    private func found(_ ip: String, isIPv4: Bool) {
        if isIPv4 { finish(ip) } else if ipv6 == nil { ipv6 = ip }
    }

    private func finish(_ ip: String?) {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
        timeout?.cancel()
        timeout = nil
        let done = done
        self.done = nil
        done?(ip.map { LocalNetworkBridgeHandler.Service(hostPort: hostPort, ipAddress: $0, txt: txt) })
    }
}
