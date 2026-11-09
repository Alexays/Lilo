import CoreAudio
import Foundation
import os

/// Captures what the Mac plays, mixed to mono Float32, except Lilo and its WebKit GPU process, which renders every page's
/// audio: a call's remote voices never come back into the share. ScreenCaptureKit's `excludesCurrentProcessAudio` only
/// drops Lilo's own process, so it would echo; a Core Audio process tap can exclude the GPU process by pid.
@safe final class SystemAudioTap: @unchecked Sendable {
    /// The rate at start, which the share's reply announces; blocks carry their own once the output device changes.
    private(set) var sampleRate: Double = 0
    private let gpuPid: @MainActor () -> pid_t?
    private let onBlock: @Sendable (Data, Double) -> Void
    private let ioQueue = DispatchQueue(label: "app.lilo.system-audio.io", qos: .userInteractive)
    /// Owns the tap, the aggregate device and the listeners once started. Apart from the IO queue, as stopping a device
    /// waits for its IO block.
    private let controlQueue = DispatchQueue(label: "app.lilo.system-audio.control", qos: .userInitiated)
    private let description: CATapDescription
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var listeners: [(selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock)] = unsafe []
    /// While false the tap delivers silence: the GPU process is unknown, or a process came or went and the exclusion is
    /// being re-resolved. A dropout beats an echo.
    private let isExclusionCurrent = OSAllocatedUnfairLock(initialState: false)
    /// IO-queue-confined: IO cycles gathered into a block.
    private var gathered = Data()

    /// `gpuPid` reads the WebKit GPU process pid, again whenever a process starts or stops playing (the GPU process
    /// may have been relaunched). `onBlock` runs on the tap's IO queue with 20 ms of samples and their rate, which
    /// follows the output device.
    @MainActor
    init?(gpuPid: @escaping @MainActor () -> pid_t?, onBlock: @escaping @Sendable (Data, Double) -> Void) {
        self.gpuPid = gpuPid
        self.onBlock = onBlock
        let pid = gpuPid()
        description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.processObjects(for: [getpid()] + (pid.map { [$0] } ?? [])))
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        isExclusionCurrent.withLock { $0 = pid != nil }
        guard unsafe AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        guard let rate = startDevice() else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        sampleRate = rate
        // A process becomes an audio object only once it opens audio, and a relaunched GPU process has a new pid:
        // re-resolve the exclusion whenever the list changes, silent until it is current again.
        listen(kAudioHardwarePropertyProcessObjectList) { [weak self] in
            guard let self else { return }
            isExclusionCurrent.withLock { $0 = false }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let pid = MainActor.assumeIsolated { self.gpuPid() }
                controlQueue.async { self.applyExclusion(gpuPid: pid) }
            }
        }
        // The aggregate is clocked by the output device: follow the switch to headphones, or the old one going away.
        listen(kAudioHardwarePropertyDefaultSystemOutputDevice) { [weak self] in
            guard let self, tap != kAudioObjectUnknown else { return }
            stopDevice()
            _ = startDevice()
        }
    }

    func stop() {
        controlQueue.sync {
            for unsafe listener in unsafe listeners {
                var address = unsafe AudioObjectPropertyAddress(mSelector: listener.selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                unsafe AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener.block)
            }
            unsafe listeners = unsafe []
            stopDevice()
            if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        unsafe AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        unsafe listeners.append((selector, block))
    }

    /// Builds the aggregate device reading the tap, clocked by the current output device, and starts it. Returns the rate.
    private func startDevice() -> Double? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        unsafe AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format)
        let rate = format.mSampleRate
        var output = AudioObjectID(kAudioObjectUnknown)
        var outputUIDRef = unsafe Unmanaged<CFString>?.none
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        unsafe AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &size, &output)
        outputAddress.mSelector = kAudioDevicePropertyDeviceUID
        size = unsafe UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        unsafe AudioObjectGetPropertyData(output, &outputAddress, 0, nil, &size, &outputUIDRef)
        let outputUID = unsafe outputUIDRef?.takeRetainedValue() as String? ?? ""
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lilo screen share audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        ioQueue.sync { gathered = Data() }
        // 20 ms per block: an IO cycle is ~10 ms, and each block costs a hop to the main thread and a page fetch.
        let blockBytes = Int(rate) / 50 * MemoryLayout<Float32>.size
        guard rate > 0, unsafe AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr,
              unsafe AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, ioQueue, { [weak self] _, input, _, _, _ in
                  guard let self, let buffer = unsafe UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
                        let bytes = unsafe buffer.mData, unsafe buffer.mDataByteSize > 0 else { return }
                  let count = unsafe Int(buffer.mDataByteSize)
                  if isExclusionCurrent.withLock({ $0 }) {
                      unsafe gathered.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
                  } else {
                      gathered.append(Data(count: count))
                  }
                  guard gathered.count >= blockBytes else { return }
                  onBlock(gathered, rate)
                  gathered = Data()
              }) == noErr, unsafe AudioDeviceStart(device, ioProc) == noErr else {
            stopDevice()
            return nil
        }
        return rate
    }

    private func stopDevice() {
        if let ioProc = unsafe ioProc {
            unsafe AudioDeviceStop(device, ioProc)
            unsafe AudioDeviceDestroyIOProcID(device, ioProc)
            unsafe self.ioProc = nil
        }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func applyExclusion(gpuPid: pid_t?) {
        guard tap != kAudioObjectUnknown, let gpuPid else { return }
        let objects = Self.processObjects(for: [getpid(), gpuPid])
        if objects != description.processes {
            description.processes = objects
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var tapDescription = unsafe Unmanaged.passUnretained(description)
            if unsafe AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &tapDescription) != noErr {
                // A running tap can refuse a new description: rebuild it around the new exclusion, silent if that fails.
                stopDevice()
                AudioHardwareDestroyProcessTap(tap)
                tap = AudioObjectID(kAudioObjectUnknown)
                guard unsafe AudioHardwareCreateProcessTap(description, &tap) == noErr, startDevice() != nil else { return }
            }
        }
        isExclusionCurrent.withLock { $0 = true }
    }

    private static func processObjects(for pids: [pid_t]) -> [AudioObjectID] {
        pids.compactMap { pid in
            var pid = pid
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            unsafe AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            return object == kAudioObjectUnknown ? nil : object
        }
    }
}

/// The "System Audio Recording" grant a process tap needs, which the screen picker's consent does not cover. macOS has
/// no public way to read or request it ahead of the tap, so this uses TCC's SPI when present: without it the tap's own
/// start prompts, and a refusal yields silence.
enum SystemAudioAccess: String {
    case granted, denied, undetermined

    nonisolated(unsafe) private static let service = "kTCCServiceAudioCapture" as CFString
    nonisolated(unsafe) private static let tcc = unsafe dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var current: SystemAudioAccess {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let symbol = unsafe dlsym(tcc, "TCCAccessPreflight") else { return .undetermined }
        switch unsafe unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt when the user was never asked; true when capture is allowed (or cannot be known).
    static func request() async -> Bool {
        switch current {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
            guard let symbol = unsafe dlsym(tcc, "TCCAccessRequest") else { return true }
            return await withCheckedContinuation { continuation in
                unsafe unsafeBitCast(symbol, to: Request.self)(service, nil) { continuation.resume(returning: $0) }
            }
        }
    }
}
