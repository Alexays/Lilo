import AVFoundation
import CoreAudio

/// The Mac's cameras, microphones, and outputs: what is connected, which one is the default, and
/// change signals. Audio defaults are system-wide (CoreAudio); the camera has no system default,
/// so the preferred camera is Lilo's own (`userPreferredCamera`), which WebKit follows.
@MainActor
final class SystemMediaDevices: NSObject {
    enum Change {
        case defaultChanged(MediaDeviceRole)
        case devicesChanged
    }

    var onChange: ((Change) -> Void)?

    private var audioListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var observesPreferredCamera = false

    func start() {
        guard audioListeners.isEmpty else { return }
        let watched: [(AudioObjectPropertySelector, Change)] = [
            (kAudioHardwarePropertyDefaultInputDevice, .defaultChanged(.input)),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultChanged(.output)),
            (kAudioHardwarePropertyDevices, .devicesChanged)
        ]
        for (selector, change) in watched {
            var address = Self.systemAddress(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?(change) }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                audioListeners.append((address, block))
            }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(.devicesChanged) }
            })
        }
        // A class property, so only string-key KVO on the class object reaches it (as WebKit does).
        (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: "systemPreferredCamera", options: [.new], context: nil)
        observesPreferredCamera = true
    }

    func stop() {
        for (address, block) in audioListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        audioListeners.removeAll()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        if observesPreferredCamera {
            (AVCaptureDevice.self as AnyObject).removeObserver(self, forKeyPath: "systemPreferredCamera")
            observesPreferredCamera = false
        }
    }

    // swiftlint:disable:next block_based_kvo
    override nonisolated func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [weak self] in self?.onChange?(.defaultChanged(.camera)) }
    }

    /// The device currently in use for `role`.
    func current(_ role: MediaDeviceRole) -> DeviceSetupMemory.DeviceRef? {
        switch role {
        case .camera:
            return AVCaptureDevice.systemPreferredCamera.map { .init(uid: $0.uniqueID, name: $0.localizedName) }
        case .input, .output:
            var deviceId = AudioObjectID(0)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = Self.systemAddress(Self.defaultSelector(role))
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceId) == noErr else { return nil }
            return Self.audioRef(deviceId)
        }
    }

    /// Makes `uid` the device for `role` when it is connected. Returns whether it is now in use.
    @discardableResult
    func select(_ uid: String, for role: MediaDeviceRole) -> Bool {
        switch role {
        case .camera:
            guard let camera = Self.cameras().first(where: { $0.uniqueID == uid }) else { return false }
            AVCaptureDevice.userPreferredCamera = camera
            return true
        case .input, .output:
            guard var deviceId = Self.audioDeviceIds(for: role).first(where: { Self.audioRef($0)?.uid == uid }) else { return false }
            var address = Self.systemAddress(Self.defaultSelector(role))
            let size = UInt32(MemoryLayout<AudioObjectID>.size)
            return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &deviceId) == noErr
        }
    }

    private static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func defaultSelector(_ role: MediaDeviceRole) -> AudioObjectPropertySelector {
        role == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Connected audio devices that have streams in the role's direction.
    private static func audioDeviceIds(for role: MediaDeviceRole) -> [AudioObjectID] {
        var address = systemAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        let scope = role == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    private static func audioRef(_ id: AudioObjectID) -> DeviceSetupMemory.DeviceRef? {
        guard let uid = audioString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return .init(uid: uid, name: audioString(id, kAudioObjectPropertyName) ?? uid)
    }

    private static func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = systemAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
