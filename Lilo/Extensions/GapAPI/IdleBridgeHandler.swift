import AppKit
import CoreGraphics
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
    /// Screen lock and unlock observers, registered only while an extension listens.
    nonisolated(unsafe) private var lockObservers: [Any] = []
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
                    self?.update()
                }
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    var isPolling: Bool { pollTimer != nil || !lockObservers.isEmpty }

    func handle(_ call: GapCall) async -> Any? {
        let listener = Listener(registry: ObjectIdentifier(call.registry), extensionId: call.extensionId)
        switch call.action {
        case "idle.queryState":
            let threshold = Self.clampInterval(call.double("detectionIntervalInSeconds") ?? detectionIntervals[listener] ?? Self.defaultInterval)
            return Self.screenIsLocked ? "locked" : idleSeconds() >= threshold ? "idle" : "active"

        case "idle.setDetectionInterval":
            detectionIntervals[listener] = Self.clampInterval(call.double("intervalInSeconds") ?? Self.defaultInterval)
            update()
            return nil

        default:
            return nil
        }
    }

    // MARK: - onStateChanged

    /// The extensions holding the idle permission that listen to onStateChanged, in every profile.
    private var audience: [(listener: Listener, registry: ProfileExtensionRegistry)] {
        (registriesProvider?() ?? []).flatMap { registry in
            registry.gapEvents.listeners(among: registry.extensionIds(withPermission: "idle"), namespace: "idle", event: "onStateChanged")
                .map { (Listener(registry: ObjectIdentifier(registry), extensionId: $0), registry) }
        }
    }

    /// Tells each listener its state when it changed, then waits for the next possible change: an active
    /// listener's threshold, any input while one is idle, the unlock while locked. Stops while nobody listens.
    private func update(locked knownLock: Bool? = nil) {
        pollTimer?.invalidate()
        pollTimer = nil
        let audience = audience
        guard !audience.isEmpty else {
            lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            lockObservers = []
            lastStates = [:]
            return
        }
        if lockObservers.isEmpty {
            lockObservers = [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)].map { name, isLock in
                DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update(locked: isLock) }
                }
            }
        }
        let locked = knownLock ?? Self.screenIsLocked
        let idle = locked ? 0 : idleSeconds()
        var states: [Listener: String] = [:]
        var nextCheck = Double.infinity
        for (listener, registry) in audience {
            let threshold = detectionIntervals[listener] ?? Self.defaultInterval
            let state = locked ? "locked" : idle >= threshold ? "idle" : "active"
            if !locked {
                // Only a poll sees the input that ends idle; active lasts at least until the threshold.
                nextCheck = min(nextCheck, state == "idle" ? 1 : threshold - idle)
            }
            states[listener] = state
            // The first sample only sets the baseline.
            if let previous = lastStates[listener], previous != state {
                registry.gapEvents.emit("idle", "onStateChanged", args: [state], to: [listener.extensionId])
            }
        }
        lastStates = states
        guard nextCheck.isFinite else { return }
        // Capped so an unreachable threshold cannot overflow the timer's fire date.
        let timer = Timer(timeInterval: min(nextCheck, 86_400), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Chrome rejects detection intervals below 15s; clamp so a 0/negative value can't make
    /// `queryState` report "idle" unconditionally.
    static func clampInterval(_ seconds: Double) -> Double {
        seconds.isFinite ? max(seconds, 15) : 60
    }

    // MARK: - State Detection

    /// The session's lock state, under an undocumented but long-stable CGSession key.
    private static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

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
