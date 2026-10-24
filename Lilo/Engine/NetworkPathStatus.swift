import Network

/// App-wide view of the default network path: current satisfaction plus one-shot callbacks
/// fired on the next change to a satisfied path. Callbacks run on the main actor.
@MainActor
final class NetworkPathStatus {
    static let shared = NetworkPathStatus()

    /// Defaults to true until the monitor delivers its first update, so early consumers
    /// treat the network as up rather than queueing behind a connectivity gain.
    private(set) var isSatisfied = true
    private var path: NWPath?
    private var onNextChange: [() -> Void] = []
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in NetworkPathStatus.shared.update(path) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// Runs `action` once on the next change to a satisfied path: back online, or onto another
    /// interface or route (Wi-Fi to tethering), when a slow or lossy link often gets better.
    func runOnNextChange(_ action: @escaping @MainActor () -> Void) {
        onNextChange.append(action)
    }

    /// Runs `action` immediately if the path is satisfied, otherwise once it next is.
    func runWhenSatisfied(_ action: @escaping @MainActor () -> Void) {
        if isSatisfied { action() } else { runOnNextChange(action) }
    }

    private func update(_ newPath: NWPath) {
        let changed = newPath != path
        path = newPath
        isSatisfied = newPath.status == .satisfied
        guard isSatisfied, changed, !onNextChange.isEmpty else { return }
        let pending = onNextChange
        onNextChange = []
        pending.forEach { $0() }
    }
}
