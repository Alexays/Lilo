import AppKit
import IOKit
import IOKit.ps

/// Whether the Mac is closed and unused: lid down with no external display, from root-domain interest notifications and screen changes.
/// The callback context is unretained: deinit removes the notification before it can dangle.
@MainActor
final class LidObserver {
    private(set) var isClosed: Bool
    var onChange: ((Bool) -> Void)?
    private let rootDomain: io_service_t
    nonisolated(unsafe) private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var debounce: DispatchWorkItem?
    nonisolated(unsafe) private var screens: NSObjectProtocol?

    init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        isClosed = Self.readClosed(rootDomain)
        screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            let observer = Unmanaged<LidObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observer.scheduleRefresh() }
        }, context, &notification)
    }

    // Dropped on the main thread, where the port delivers: no callback races the teardown.
    deinit {
        IOObjectRelease(notification)
        IONotificationPortDestroy(port)
        IOObjectRelease(rootDomain)
        if let screens { NotificationCenter.default.removeObserver(screens) }
    }

    // A lid that flaps while closing settles within 2 s; an opening lid is reported at once, so
    // the panel lights up again without a dark wait.
    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let closed = Self.readClosed(rootDomain)
            guard closed != isClosed else { return }
            isClosed = closed
            onChange?(closed)
        }
        debounce = work
        if Self.readClosed(rootDomain) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        } else {
            work.perform()
        }
    }

    private static func readClosed(_ service: io_service_t) -> Bool {
        let lid = (IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
        guard lid else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return !ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

/// Charger or battery and the internal battery's level, from IOPS change events. An unreadable
/// level on battery is read again every 30 s, since IOPS sends no event for a read that fails.
@MainActor
final class PowerSourceMonitor {
    private(set) var onBattery = false
    private(set) var percent: Int?
    var onChange: (() -> Void)?
    nonisolated(unsafe) private var source: CFRunLoopSource?
    private var retry: DispatchWorkItem?

    init() {
        read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    // The source's context is an unretained `self`.
    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }

    private func refresh() {
        read()
        onChange?()
    }

    private func read() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let battery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        percent = battery.flatMap { description in
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
            return current * 100 / maximum
        }
        retry?.cancel()
        guard onBattery, percent == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }
}
