import AppKit

/// Puts back the camera, microphone, and output remembered for the connected displays, and
/// remembers the user's own picks per display setup. Off unless the setting enables it: while off
/// it observes nothing and never touches the system.
@MainActor
final class DeviceSetupController {
    static let enabledKey = "autoDeviceSwitching"
    private static let memoryKey = "deviceSetups"
    /// A dock brings its webcam and audio up a few seconds after its display: keep applying the
    /// setup as devices appear for this long after a display change.
    private static let applyRetryWindow: TimeInterval = 10

    private let settingsStore: SettingsStore
    private let devices = SystemMediaDevices()
    private var memory: DeviceSetupMemory
    private var screenObserver: NSObjectProtocol?
    private var setupKey = ""
    private var setupLabel = ""
    private var lastAppliedAt = Date.distantPast
    private var lastDevicesChangedAt = Date.distantPast
    private var applyRetryUntil = Date.distantPast

    /// Fired whenever what the settings row shows may have changed.
    var onStateChange: (() -> Void)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        memory = DeviceSetupMemory(json: settingsStore.get(Self.memoryKey))
        devices.onChange = { [weak self] change in self?.handle(change) }
        if isEnabled { start() }
    }

    var isEnabled: Bool { settingsStore.get(Self.enabledKey) == "true" }

    /// Follows the setting; the store already holds the new value.
    func enabledDidChange() {
        if isEnabled { start() } else { stop() }
        onStateChange?()
    }

    func forgetCurrentSetup() {
        memory.forget(setupKey)
        settingsStore.set(Self.memoryKey, value: memory.json)
        onStateChange?()
    }

    var bridgeState: [String: Any] {
        var state: [String: Any] = ["label": setupLabel]
        for (role, device) in memory.setup(for: setupKey)?.devices ?? [:] {
            state[role.rawValue] = device.name
        }
        return state
    }

    private func start() {
        guard screenObserver == nil else { return }
        devices.start()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        screensChanged()
    }

    private func stop() {
        guard let screenObserver else { return }
        NotificationCenter.default.removeObserver(screenObserver)
        self.screenObserver = nil
        devices.stop()
        // Re-enabling must treat the current displays as a new setup and apply it.
        setupKey = ""
    }

    private func screensChanged() {
        let external = NSScreen.screens.compactMap { screen -> (uuid: String, name: String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayId = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsBuiltin(displayId) == 0,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(displayId)?.takeRetainedValue(),
                  let uuidString = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return (uuidString, screen.localizedName)
        }
        let key = DeviceSetupMemory.setupKey(externalDisplayUUIDs: external.map(\.uuid))
        // Screen parameters also change on resolution or arrangement edits: same setup, nothing to do.
        guard key != setupKey else { return }
        setupKey = key
        setupLabel = external.map(\.name).sorted().joined(separator: " + ")
        applyRetryUntil = Date().addingTimeInterval(Self.applyRetryWindow)
        applySetup()
        onStateChange?()
    }

    private func handle(_ change: SystemMediaDevices.Change) {
        let now = Date()
        switch change {
        case .devicesChanged:
            lastDevicesChangedAt = now
            if now < applyRetryUntil { applySetup() }
        case .defaultChanged(let role):
            guard let device = devices.current(role) else { return }
            let recorded = memory.record(
                device, role: role, setupKey: setupKey, label: setupLabel,
                now: now, lastAppliedAt: lastAppliedAt, lastDevicesChangedAt: lastDevicesChangedAt
            )
            guard recorded else { return }
            settingsStore.set(Self.memoryKey, value: memory.json)
        }
        onStateChange?()
    }

    private func applySetup() {
        guard let setup = memory.setup(for: setupKey) else { return }
        for (role, device) in setup.devices where devices.current(role)?.uid != device.uid {
            if devices.select(device.uid, for: role) { lastAppliedAt = Date() }
        }
    }
}
