import CoreAudio
import Foundation

/// Captures what the Mac plays, mixed to mono Float32, except Lilo and its WebKit GPU process, which renders every page's
/// audio: a call's remote voices never come back into the share. ScreenCaptureKit's `excludesCurrentProcessAudio` only
/// drops Lilo's own process, so it would echo; a Core Audio process tap can exclude the GPU process by pid.
final class SystemAudioTap: @unchecked Sendable {
    let sampleRate: Double
    private let gpuPid: @MainActor () -> pid_t?
    private let queue = DispatchQueue(label: "app.lilo.system-audio", qos: .userInteractive)
    private let description: CATapDescription
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var processListListener: AudioObjectPropertyListenerBlock?
    /// Queue-confined. While false the tap delivers silence: the GPU process is unknown, or a process came or went and
    /// the exclusion is being re-resolved. A dropout beats an echo.
    private var isExclusionCurrent = false

    private static let processList = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// `gpuPid` reads the WebKit GPU process pid, again whenever a process starts or stops playing (the GPU process
    /// may have been relaunched). `onBlock` runs on the tap's queue with one IO cycle (512 frames, ~10 ms at 48 kHz).
    @MainActor
    init?(gpuPid: @escaping @MainActor () -> pid_t?, onBlock: @escaping @Sendable (Data) -> Void) {
        self.gpuPid = gpuPid
        let pid = gpuPid()
        description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.processObjects(for: [getpid()] + (pid.map { [$0] } ?? [])))
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        isExclusionCurrent = pid != nil
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format)
        sampleRate = format.mSampleRate
        // The output device clocks the aggregate, as the tap follows what it plays.
        var output = AudioObjectID(kAudioObjectUnknown)
        var outputUID = "" as CFString
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &size, &output)
        outputAddress.mSelector = kAudioDevicePropertyDeviceUID
        size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(output, &outputAddress, 0, nil, &size, &outputUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lilo screen share audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        guard format.mSampleRate > 0, AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr,
              AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, queue, { [weak self] _, input, _, _, _ in
                  guard let self, let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
                        let bytes = buffer.mData, buffer.mDataByteSize > 0 else { return }
                  let count = Int(buffer.mDataByteSize)
                  onBlock(self.isExclusionCurrent ? Data(bytes: bytes, count: count) : Data(count: count))
              }) == noErr, AudioDeviceStart(device, ioProc) == noErr else {
            stop()
            return nil
        }
        // A process becomes an audio object only once it opens audio, and a relaunched GPU process has a new pid:
        // re-resolve the exclusion whenever the list changes, silent until it is current again.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            isExclusionCurrent = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let pid = MainActor.assumeIsolated { self.gpuPid() }
                queue.async { self.applyExclusion(gpuPid: pid) }
            }
        }
        processListListener = listener
        var address = Self.processList
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }

    func stop() {
        queue.sync {
            if let processListListener {
                var address = Self.processList
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, processListListener)
                self.processListListener = nil
            }
        }
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
        }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func applyExclusion(gpuPid: pid_t?) {
        guard tap != kAudioObjectUnknown, let gpuPid else { return }
        let objects = Self.processObjects(for: [getpid(), gpuPid])
        if objects != description.processes {
            description.processes = objects
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var tapDescription = description
            guard AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), &tapDescription) == noErr else { return }
        }
        isExclusionCurrent = true
    }

    private static func processObjects(for pids: [pid_t]) -> [AudioObjectID] {
        pids.compactMap { pid in
            var pid = pid
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
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
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var current: SystemAudioAccess {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .undetermined }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
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
            guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return true }
            return await withCheckedContinuation { continuation in
                unsafeBitCast(symbol, to: Request.self)(service, nil) { continuation.resume(returning: $0) }
            }
        }
    }
}
