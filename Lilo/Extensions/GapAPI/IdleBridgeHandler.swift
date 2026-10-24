import AppKit
import IOKit

/// chrome.idle gap bridge using IOKit HID idle time.
@MainActor
final class IdleBridgeHandler: GapHandler {
    private var detectionInterval: Double = 60
    /// Every loaded profile's registry: the idle state is the machine's, so each profile's
    /// extensions hear onStateChanged. `nil` leaves the poller dormant.
    private let registriesProvider: (() -> [ProfileExtensionRegistry])?
    nonisolated(unsafe) private var pollTimer: Timer?
    nonisolated(unsafe) private var runtimeLoadObserver: Any?
    /// Last state the poller emitted (or established as baseline); nil means no baseline yet.
    private var lastPolledState: String?

    let gapActions: Set<String> = [
        "idle.queryState",
        "idle.setDetectionInterval"
    ]

    init(registriesProvider: (() -> [ProfileExtensionRegistry])? = nil) {
        self.registriesProvider = registriesProvider
        guard registriesProvider != nil else { return }
        // The poller runs only while some loaded extension holds the idle permission. A
        // listener-only extension never issues a bridge call, so a runtime load is the only
        // signal that polling may now have an audience.
        runtimeLoadObserver = NotificationCenter.default.addObserver(
            forName: .extensionRuntimeLoaded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startPollingIfInterested() }
        }
    }

    deinit {
        pollTimer?.invalidate()
        runtimeLoadObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    var isPolling: Bool { pollTimer != nil }

    func handle(_ call: GapCall) async -> Any? {
        switch call.action {
        case "idle.queryState":
            if pollTimer == nil { startPolling() }  // a live idle.* call is evidence of interest
            let threshold = Self.clampInterval(call.double("detectionIntervalInSeconds") ?? detectionInterval)
            return queryState(threshold: threshold)

        case "idle.setDetectionInterval":
            detectionInterval = Self.clampInterval(call.double("intervalInSeconds") ?? 60)
            startPolling()  // reschedule at the new interval
            return nil

        default:
            return nil
        }
    }

    // MARK: - onStateChanged polling

    /// The registries with an extension holding the idle permission.
    private var audience: [ProfileExtensionRegistry] {
        (registriesProvider?() ?? []).filter { !$0.extensionIds(withPermission: "idle").isEmpty }
    }

    private func startPollingIfInterested() {
        guard pollTimer == nil, !audience.isEmpty else { return }
        startPolling()
    }

    private func startPolling() {
        guard registriesProvider != nil else { return }
        pollTimer?.invalidate()
        let interval = Self.clampInterval(detectionInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = interval * 0.5  // off the hot path; presence detection tolerates slack
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        let audience = audience
        guard !audience.isEmpty else {
            // No audience: stop until the next idle.* call or extension load re-arms the poller,
            // and drop the baseline so the next one re-establishes it.
            pollTimer?.invalidate()
            pollTimer = nil
            lastPolledState = nil
            return
        }
        let state = queryState(threshold: detectionInterval)
        let previous = lastPolledState
        lastPolledState = state
        // The first sample only sets the baseline.
        guard let previous, previous != state else { return }
        for registry in audience {
            registry.emitGapEvent("idle", "onStateChanged", args: [state], requiredPermission: "idle")
        }
    }

    /// Chrome rejects detection intervals below 15s; clamp so a 0/negative value can't make
    /// `queryState` report "idle" unconditionally.
    static func clampInterval(_ seconds: Double) -> Double {
        seconds.isFinite ? max(seconds, 15) : 60
    }

    // MARK: - State Detection

    private func queryState(threshold: Double) -> String {
        idleSeconds() >= threshold ? "idle" : "active"
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
