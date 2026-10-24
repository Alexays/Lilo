import AppKit
import DiskArbitration

/// chrome.system.cpu, .memory, .storage and .display, read from the same sources as Chrome on macOS.
/// Display and volume changes arrive as notifications; mounted volumes are only tracked once an
/// extension holding system.storage is loaded or calls it.
@MainActor
final class SystemBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "system.cpu.getInfo", "system.memory.getInfo",
        "system.storage.getInfo", "system.storage.ejectDevice",
        "system.display.getInfo"
    ]

    struct StorageUnit: Sendable {
        /// Chrome's storage monitor id: the kind of device, then its volume UUID or its vendor, model and revision.
        let deviceId: String
        let name: String
        let location: String
        let removable: Bool
        let capacity: Double
    }

    private let registriesProvider: () -> [ProfileExtensionRegistry]
    /// Chrome's transient ids: a random one per device, stable while the app runs.
    private var transientIds: [String: String] = [:]
    /// Mounted units by volume path while storage is tracked, so an unmount can name its device.
    private var mounted: [String: StorageUnit]?
    nonisolated(unsafe) private var observers: [(NotificationCenter, Any)] = []

    init(registriesProvider: @escaping () -> [ProfileExtensionRegistry]) {
        self.registriesProvider = registriesProvider
        let center = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit("system.display", "onDisplayChanged", args: []) }
            }),
            // A listener-only extension never calls in: its load is the signal to start tracking volumes.
            (center, center.addObserver(forName: .extensionRuntimeLoaded, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.mounted == nil,
                          self.registriesProvider().contains(where: { !$0.extensionIds(withPermission: "system.storage").isEmpty }) else { return }
                    self.trackStorage()
                }
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                MainActor.assumeIsolated { self?.volumeMounted(url) }
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                MainActor.assumeIsolated { self?.volumeUnmounted(url) }
            })
        ]
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    func handle(_ call: GapCall) async -> Any? {
        switch call.action {
        case "system.cpu.getInfo":
            return Self.cpuInfo()
        case "system.memory.getInfo":
            return ["capacity": Double(ProcessInfo.processInfo.physicalMemory), "availableCapacity": Self.availableMemory()]
        case "system.storage.getInfo":
            trackStorage()
            return await Task.detached { Self.storageUnits() }.value.map(storageInfo)
        case "system.storage.ejectDevice":
            trackStorage()
            return await eject(transientId: call.string("id") ?? "")
        case "system.display.getInfo":
            return Self.displayInfo()
        default:
            return nil
        }
    }

    private func emit(_ namespace: String, _ event: String, args: [Any]) {
        for registry in registriesProvider() {
            registry.emitGapEvent(namespace, event, args: args, requiredPermission: namespace)
        }
    }

    // MARK: - CPU and memory

    private static func cpuInfo() -> [String: Any] {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isTranslated = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        #if arch(arm64)
        let archName = "arm64"
        let features: [String] = []
        #else
        let archName = isTranslated ? "arm64" : "x86_64"
        // base::CPU's features, which Chrome lists on x86 only.
        let cpuFeatures = Set((sysctlString("machdep.cpu.features") ?? "").split(separator: " ").map(String.init))
        let features = [("MMX", "mmx"), ("SSE", "sse"), ("SSE2", "sse2"), ("SSE3", "sse3"), ("SSSE3", "ssse3"), ("SSE4.1", "sse4_1"), ("SSE4.2", "sse4_2"), ("AVX1.0", "avx")]
            .filter { cpuFeatures.contains($0.0) }.map(\.1)
        #endif
        return [
            "numOfProcessors": ProcessInfo.processInfo.activeProcessorCount,
            "archName": archName,
            "modelName": sysctlString("machdep.cpu.brand_string") ?? "",
            "features": features,
            // Chrome reports no per-processor times under Rosetta.
            "processors": isTranslated ? [] : processorTimes(),
            "temperatures": [Double]()
        ]
    }

    /// Cumulative ticks per processor, nice time counted as user time as in Chrome.
    private static func processorTimes() -> [[String: Any]] {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { processor in
            let ticks = { (state: Int32) in Double(UInt32(bitPattern: info[processor * Int(CPU_STATE_MAX) + Int(state)])) }
            let user = ticks(CPU_STATE_USER) + ticks(CPU_STATE_NICE), kernel = ticks(CPU_STATE_SYSTEM), idle = ticks(CPU_STATE_IDLE)
            return ["usage": ["user": user, "kernel": kernel, "idle": idle, "total": user + kernel + idle]]
        }
    }

    /// Chrome's figure: free pages that are not speculative, plus the file-backed cache.
    private static func availableMemory() -> Double {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let free = stats.free_count >= stats.speculative_count ? stats.free_count - stats.speculative_count : 0
        return Double(UInt64(free) + UInt64(stats.external_page_count)) * Double(getpagesize())
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // MARK: - Storage

    /// Mounted mass-storage volumes as Chrome's storage monitor lists them, in device id order.
    nonisolated static func storageUnits() -> [StorageUnit] {
        guard let session = DASessionCreate(nil) else { return [] }
        var seen = Set<String>()
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .compactMap { storageUnit(at: $0, session: session) }
            .filter { seen.insert($0.deviceId).inserted }
            .sorted { $0.deviceId < $1.deviceId }
    }

    nonisolated private static func storageUnit(at url: URL, session: DASession) -> StorageUnit? {
        guard let disk = DADiskCreateFromVolumePath(nil, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String, !bsdName.isEmpty,
              let location = (description[kDADiskDescriptionVolumePathKey as String] as? URL)?.path, !location.isEmpty else { return nil }
        let text = { (key: CFString) in description[key as String] as? String ?? "" }
        let vendor = text(kDADiskDescriptionDeviceVendorKey), model = text(kDADiskDescriptionDeviceModelKey)
        let label = text(kDADiskDescriptionVolumeNameKey)
        guard model != "Disk Image" else { return nil }
        let joined = { (parts: [String]) in parts.filter { !$0.isEmpty }.joined(separator: " ") }
        var uniqueId = joined([vendor, model, text(kDADiskDescriptionDeviceRevisionKey)])
        if let uuid = description[kDADiskDescriptionVolumeUUIDKey as String] as CFTypeRef?, CFGetTypeID(uuid) == CFUUIDGetTypeID() {
            uniqueId = CFUUIDCreateString(nil, (uuid as! CFUUID)) as String
        }
        guard !uniqueId.isEmpty else { return nil }
        let removable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        return StorageUnit(
            deviceId: (removable ? "nodcim:" : "path:") + uniqueId,
            // Chrome names a fixed volume by its label, else its path; a removable one by its label, else its product.
            name: label.isEmpty ? (removable ? joined([vendor, model]) : location) : label,
            location: location,
            removable: removable,
            capacity: (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private func transientId(for deviceId: String) -> String {
        if let id = transientIds[deviceId] { return id }
        let id = UUID().uuidString.lowercased()
        transientIds[deviceId] = id
        return id
    }

    private func storageInfo(_ unit: StorageUnit) -> [String: Any] {
        ["id": transientId(for: unit.deviceId), "name": unit.name, "type": unit.removable ? "removable" : "fixed", "capacity": unit.capacity]
    }

    private func trackStorage() {
        guard mounted == nil else { return }
        mounted = [:]
        Task { [weak self] in
            let units = await Task.detached { Self.storageUnits() }.value
            for unit in units where self?.mounted?[unit.location] == nil { self?.mounted?[unit.location] = unit }
        }
    }

    /// Chrome only reports removable storage coming and going.
    private func volumeMounted(_ url: URL) {
        guard mounted != nil else { return }
        Task { [weak self] in
            let unit = await Task.detached { DASessionCreate(nil).flatMap { Self.storageUnit(at: url, session: $0) } }.value
            guard let self, let unit, self.mounted?.values.contains(where: { $0.deviceId == unit.deviceId }) == false else { return }
            self.mounted?[unit.location] = unit
            if unit.removable { self.emit("system.storage", "onAttached", args: [self.storageInfo(unit)]) }
        }
    }

    private func volumeUnmounted(_ url: URL) {
        guard let unit = mounted?.removeValue(forKey: url.path), unit.removable else { return }
        emit("system.storage", "onDetached", args: [transientId(for: unit.deviceId)])
    }

    /// As in Chrome, the device is reported detached before it is unmounted, and any refusal reads as in use.
    private func eject(transientId id: String) async -> String {
        guard let deviceId = transientIds.first(where: { $0.value == id })?.key,
              let unit = await Task.detached(operation: { Self.storageUnits() }).value.first(where: { $0.deviceId == deviceId }) else {
            return "no_such_device"
        }
        mounted?[unit.location] = nil
        if unit.removable { emit("system.storage", "onDetached", args: [id]) }
        let location = URL(fileURLWithPath: unit.location)
        let ejected = await Task.detached { (try? NSWorkspace.shared.unmountAndEjectDevice(at: location)) != nil }.value
        return ejected ? "success" : "in_use"
    }

    // MARK: - Display

    /// Chrome's DisplayUnitInfo on macOS: geometry in points from the primary screen's top-left
    /// corner; it leaves names, DPI, modes and zoom factors unset there.
    private static func displayInfo() -> [[String: Any]] {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        let bounds = { (rect: NSRect) -> [String: Any] in
            ["left": Int(rect.minX.rounded()), "top": Int((primaryHeight - rect.maxY).rounded()), "width": Int(rect.width.rounded()), "height": Int(rect.height.rounded())]
        }
        return screens.enumerated().map { index, screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return [
                "id": String(id), "name": "", "mirroringSourceId": "", "mirroringDestinationIds": [String](),
                "isPrimary": index == 0, "isInternal": CGDisplayIsBuiltin(id) != 0, "isEnabled": true, "activeState": "active",
                "isUnified": false, "dpiX": 0, "dpiY": 0, "rotation": Int(CGDisplayRotation(id)),
                "bounds": bounds(screen.frame), "overscan": ["left": 0, "top": 0, "right": 0, "bottom": 0],
                "workArea": bounds(screen.visibleFrame), "modes": [Any](), "hasTouchSupport": false,
                "hasAccelerometerSupport": false, "availableDisplayZoomFactors": [Double](), "displayZoomFactor": 0
            ]
        }
    }
}
