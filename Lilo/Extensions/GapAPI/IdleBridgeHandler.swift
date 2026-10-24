import AppKit
import IOKit

/// chrome.idle gap bridge using IOKit HID idle time.
@MainActor
final class IdleBridgeHandler: GapHandler {
    /// An extension of one profile: Chrome keeps a detection interval, and a state, per extension.
    private struct Listener: Hashable {
        let registry: ObjectIdentifier
        let extensionId: String
    }

    private static let defaultInterval: Double = 60
    private var detectionIntervals: [Listener: Double] = [:]
    /// Every loaded profile's registry: the idle state is the machine's, so each profile's
    /// extensions hear onStateChanged. `nil` leaves the poller dormant.
    private let registriesProvider: (() -> [ProfileExtensionRegistry])?
    nonisolated(unsafe) private var pollTimer: Timer?
    nonisolated(unsafe) private var observers: [Any] = []
    /// The state each listener was last told, or took as its baseline.
    private var lastStates: [Listener: String] = [:]

    let gapActions: Set<String> = [
        "idle.queryState",
        "idle.setDetectionInterval"
    ]

    init(registriesProvider: (() -> [ProfileExtensionRegistry])? = nil) {
        self.registriesProvider = registriesProvider
        guard registriesProvider != nil else { return }
        // The poller runs only while an extension holding the idle permission listens to onStateChanged:
        // a load or a listener change is when that may start or stop.
        observers = [Notification.Name.extensionRuntimeLoaded, .extensionGapListenersChanged].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.schedulePolling(for: self.audience)
                }
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var isPolling: Bool { pollTimer != nil }

    func handle(_ call: GapCall) async -> Any? {
        let listener = Listener(registry: ObjectIdentifier(call.registry), extensionId: call.extensionId)
        switch call.action {
        case "idle.queryState":
            let threshold = Self.clampInterval(call.double("detectionIntervalInSeconds") ?? detectionIntervals[listener] ?? Self.defaultInterval)
            return idleSeconds() >= threshold ? "idle" : "active"

        case "idle.setDetectionInterval":
            detectionIntervals[listener] = Self.clampInterval(call.double("intervalInSeconds") ?? Self.defaultInterval)
            schedulePolling(for: audience)
            return nil

        default:
            return nil
        }
    }

    // MARK: - onStateChanged polling

    /// The extensions holding the idle permission that listen to onStateChanged, in every profile.
    private var audience: [(listener: Listener, registry: ProfileExtensionRegistry)] {
        (registriesProvider?() ?? []).flatMap { registry in
            registry.gapEvents.listeners(among: registry.extensionIds(withPermission: "idle"), namespace: "idle", event: "onStateChanged")
                .map { (Listener(registry: ObjectIdentifier(registry), extensionId: $0), registry) }
        }
    }

    /// Polls at the shortest detection interval of `audience`, or stops while it is empty.
    private func schedulePolling(for audience: [(listener: Listener, registry: ProfileExtensionRegistry)]) {
        guard let interval = audience.map({ detectionIntervals[$0.listener] ?? Self.defaultInterval }).min() else {
            pollTimer?.invalidate()
            pollTimer = nil
            lastStates = [:]
            return
        }
        guard pollTimer?.timeInterval != interval else { return }
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval * 0.5  // off the hot path; presence detection tolerates slack
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        let audience = audience
        schedulePolling(for: audience)
        guard !audience.isEmpty else { return }
        let idle = idleSeconds()
        var states: [Listener: String] = [:]
        for (listener, registry) in audience {
            let state = idle >= detectionIntervals[listener] ?? Self.defaultInterval ? "idle" : "active"
            states[listener] = state
            // The first sample only sets the baseline.
            if let previous = lastStates[listener], previous != state {
                registry.gapEvents.emit("idle", "onStateChanged", args: [state], to: [listener.extensionId])
            }
        }
        lastStates = states
    }

    /// Chrome rejects detection intervals below 15s; clamp so a 0/negative value can't make
    /// `queryState` report "idle" unconditionally.
    static func clampInterval(_ seconds: Double) -> Double {
        seconds.isFinite ? max(seconds, 15) : 60
    }

    // MARK: - State Detection

    private func idleSeconds() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return 0 }
        defer { IOObjectRelease(service) }
        guard let cfProp = IORegistryEntryCreateCFProperty(
            service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0
        ) else { return 0 }
        let property = cfProp.takeRetainedValue()
        guard CFGetTypeID(property) == CFNumberGetTypeID() else { return 0 }
        let idleTime = property as! CFNumber
        var nanoseconds: Int64 = 0
        CFNumberGetValue(idleTime, .sInt64Type, &nanoseconds)
        return Double(nanoseconds) / 1_000_000_000
    }
}
