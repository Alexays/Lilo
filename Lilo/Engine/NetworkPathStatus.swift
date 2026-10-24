import Network

/// App-wide view of the default network path: current satisfaction plus one-shot callbacks
/// fired on the next transition to satisfied. Callbacks run on the main actor.
@MainActor
final class NetworkPathStatus {
    static let shared = NetworkPathStatus()

    /// Defaults to true until the monitor delivers its first update, so early consumers
    /// treat the network as up rather than queueing behind a connectivity gain.
    private(set) var isSatisfied = true
    private var onNextSatisfied: [() -> Void] = []
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in NetworkPathStatus.shared.update(satisfied: satisfied) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// Runs `action` immediately if the path is satisfied, otherwise once on the next
    /// transition to satisfied.
    func runWhenSatisfied(_ action: @escaping @MainActor () -> Void) {
        if isSatisfied { action() } else { onNextSatisfied.append(action) }
    }

    private func update(satisfied: Bool) {
        isSatisfied = satisfied
        guard satisfied, !onNextSatisfied.isEmpty else { return }
        let pending = onNextSatisfied
        onNextSatisfied = []
        pending.forEach { $0() }
    }
}
