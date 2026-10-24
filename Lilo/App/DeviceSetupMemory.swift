import Foundation

/// A capture or playback role Lilo picks a device for.
enum MediaDeviceRole: String, CaseIterable, Codable, CodingKeyRepresentable {
    case camera, input, output
}

/// The devices chosen for each display setup, and the rules deciding when a system default change
/// is the user's choice (remembered) or an automatic switch (ignored). Pure: no system access.
struct DeviceSetupMemory: Equatable {
    struct DeviceRef: Codable, Equatable {
        let uid: String
        let name: String
    }

    struct Setup: Codable, Equatable {
        var label: String
        var devices: [MediaDeviceRole: DeviceRef] = [:]
    }

    /// A change landing this soon after Lilo applied a setup is Lilo's own echo.
    static let applySettle: TimeInterval = 2
    /// A change landing this soon after a device appeared or vanished is macOS switching on its own
    /// (AirPods connecting, a webcam unplugged), not the user choosing.
    static let deviceSettle: TimeInterval = 3

    private(set) var setups: [String: Setup] = [:]

    /// One key per combination of external displays; the built-in display alone is the empty set.
    static func setupKey(externalDisplayUUIDs: [String]) -> String {
        externalDisplayUUIDs.isEmpty ? "builtin" : externalDisplayUUIDs.sorted().joined(separator: "+")
    }

    /// Remembers `device` for `role` in the setup unless the change reads as automatic. Returns
    /// whether it was remembered.
    @discardableResult
    mutating func record(
        _ device: DeviceRef,
        role: MediaDeviceRole,
        setupKey: String,
        label: String,
        now: Date,
        lastAppliedAt: Date,
        lastDevicesChangedAt: Date
    ) -> Bool {
        guard now.timeIntervalSince(lastAppliedAt) >= Self.applySettle,
              now.timeIntervalSince(lastDevicesChangedAt) >= Self.deviceSettle else { return false }
        var setup = setups[setupKey] ?? Setup(label: label)
        setup.label = label
        setup.devices[role] = device
        setups[setupKey] = setup
        return true
    }

    func setup(for key: String) -> Setup? {
        setups[key]
    }

    mutating func forget(_ key: String) {
        setups.removeValue(forKey: key)
    }
}

extension DeviceSetupMemory {
    init(json: String?) {
        let decoded = json.flatMap { try? JSONDecoder().decode([String: Setup].self, from: Data($0.utf8)) }
        self.init(setups: decoded ?? [:])
    }

    var json: String {
        (try? JSONEncoder().encode(setups)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
