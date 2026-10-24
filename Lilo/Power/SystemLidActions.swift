import AppKit
import CoreAudio
import Darwin
import ObjectiveC

/// Stops the Dock apps an agent does not need, each with its whole process tree (a browser's
/// helpers are its children). Every Lilo (another build included), its terminals, the apps Lilo
/// and the agents driving it run inside (another terminal) stay running, as do Apple's and the kept apps.
enum AppFreezer {
    static func targets(keeping kept: Set<String>, sparing agents: [pid_t] = []) -> [PowerHelperState.Frozen] {
        let lilo = getpid()
        // Debug and test builds carry a suffix (fr.arouillard.lilo.debug): every one of them is still a Lilo.
        let liloBuilds = "fr.arouillard.lilo."
        let ancestors = Set(([lilo] + agents).flatMap { start in
            sequence(first: start) { pid in
                SystemPowerBackend.info(pid).map { pid_t($0.pbi_ppid) }.flatMap { $0 > 1 && $0 != pid ? $0 : nil }
            }
        })
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, !app.isTerminated, !ancestors.contains(app.processIdentifier),
                      let id = app.bundleIdentifier else { return false }
                return id != "fr.arouillard.lilo" && !id.hasPrefix(liloBuilds) && !id.hasPrefix("com.apple.")
                    && !kept.contains(id)
            }
            // Another Lilo can also sit in a target's tree, run from a terminal or by an agent's xcodebuild.
            .flatMap { descendants(of: $0.processIdentifier) { $0 == lilo || isLilo($0) } }
            .compactMap { pid in SystemPowerBackend.info(pid).map { PowerHelperState.Frozen(pid: pid, start: $0.pbi_start_tvsec * 1_000_000 + $0.pbi_start_tvusec) } }
    }

    /// The process and every descendant, parents first, without the subtrees rooted at the processes `prunes` names.
    static func descendants(of root: pid_t, pruning prunes: (pid_t) -> Bool = { _ in false }) -> [pid_t] {
        guard !prunes(root) else { return [] }
        var tree = [root]
        var index = 0
        while index < tree.count {
            var children = [pid_t](repeating: 0, count: 256)
            let count = proc_listchildpids(tree[index], &children, Int32(children.count * MemoryLayout<pid_t>.stride))
            if count > 0 { tree += children.prefix(Int(count)).filter { !prunes($0) } }
            index += 1
        }
        return tree
    }

    /// Whether `pid` runs a Lilo executable: every build (release, debug, test host, another checkout's) is named Lilo.
    static func isLilo(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return (String(cString: path) as NSString).lastPathComponent == "Lilo"
    }
}

/// Lid-closed actions on this Mac: brightness to 0, sound off, apps and web tabs frozen, all undone
/// on open. Brightness goes through DisplayServices and CoreBrightness, which have no header: a
/// missing entry point or a changed signature leaves that light alone.
@MainActor
final class SystemLidActions: LidActions {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetKeyboard = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetKeyboard = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let savedBrightnessKey = "powerSavedBrightness"
    private static let mutedOutputKey = "powerMutedOutput"
    private let freezeWebTabs: () -> [WKWebViewTab]
    private let agentProcesses: () -> [pid_t]
    private let getDisplay: GetBrightness?
    private let setDisplay: SetBrightness?
    private let keyboard: (client: NSObject, id: UInt64)?
    private var sampled: (display: Float?, keyboard: Float?) = (nil, nil)
    private var saved: (display: Float?, keyboard: Float?) = (nil, nil)
    private var mutedDevice: AudioDeviceID?
    private var frozenTabs: [() -> WKWebViewTab?] = []

    init(freezeWebTabs: @escaping () -> [WKWebViewTab], agentProcesses: @escaping () -> [pid_t]) {
        self.freezeWebTabs = freezeWebTabs
        self.agentProcesses = agentProcesses
        let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getDisplay = dlsym(displayServices, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
        setDisplay = dlsym(displayServices, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        keyboard = Self.keyboardClient()
        restoreAfterCrash()
    }

    func sampleBrightness() {
        guard saved.display == nil else { return }
        sampled = (readDisplay(), readKeyboard())
    }

    func lidClosed(helper: PowerHelperProtocol, settings: PowerKeeper.Settings) {
        // A close the helper lost and redid keeps the values saved by the first one.
        if saved.display == nil, saved.keyboard == nil {
            saved = (sampled.display ?? readDisplay(), sampled.keyboard ?? readKeyboard())
            UserDefaults.lilo.set([saved.display ?? -1, saved.keyboard ?? -1], forKey: Self.savedBrightnessKey)
        }
        if saved.display != nil { writeDisplay(0) }
        if saved.keyboard != nil { writeKeyboard(0) }
        if mutedDevice == nil, let device = Self.defaultOutput(), Self.isMuted(device) == false, Self.setMuted(device, true) {
            mutedDevice = device
            // By UID: a device id does not survive a reboot, and a crash may outlive one.
            UserDefaults.lilo.set(Self.uid(of: device), forKey: Self.mutedOutputKey)
        }
        frozenTabs += freezeWebTabs().map { tab -> () -> WKWebViewTab? in { [weak tab] in tab } }
        guard settings.freezeApps else { return }
        let targets = AppFreezer.targets(keeping: Set(settings.neverFreeze), sparing: agentProcesses())
        helper.freeze(pids: targets.map { NSNumber(value: $0.pid) }, starts: targets.map { NSNumber(value: $0.start) }) { _ in }
    }

    func lidOpened(helper: PowerHelperProtocol) {
        helper.thaw {}
        for tab in frozenTabs { tab()?.resume() }
        frozenTabs = []
        if let device = mutedDevice {
            _ = Self.setMuted(device, false)
            mutedDevice = nil
            UserDefaults.lilo.removeObject(forKey: Self.mutedOutputKey)
        }
        if let level = saved.display { writeDisplay(level) }
        if let level = saved.keyboard { writeKeyboard(level) }
        saved = (nil, nil)
        UserDefaults.lilo.removeObject(forKey: Self.savedBrightnessKey)
    }

    // Lilo died with the lid closed: the panel and keys are still at 0, the output still muted.
    private func restoreAfterCrash() {
        if let uid = UserDefaults.lilo.string(forKey: Self.mutedOutputKey) {
            if let device = Self.device(withUID: uid) { _ = Self.setMuted(device, false) }
            UserDefaults.lilo.removeObject(forKey: Self.mutedOutputKey)
        }
        guard let levels = UserDefaults.lilo.array(forKey: Self.savedBrightnessKey) as? [Float], levels.count == 2 else { return }
        if levels[0] >= 0 { writeDisplay(levels[0]) }
        if levels[1] >= 0 { writeKeyboard(levels[1]) }
        UserDefaults.lilo.removeObject(forKey: Self.savedBrightnessKey)
    }

    private var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func readDisplay() -> Float? {
        guard let getDisplay, let display = builtInDisplay else { return nil }
        var level: Float = 0
        return getDisplay(display, &level) == 0 ? level : nil
    }

    private func writeDisplay(_ level: Float) {
        guard let setDisplay, let display = builtInDisplay else { return }
        _ = setDisplay(display, level)
    }

    private func readKeyboard() -> Float? {
        guard let keyboard else { return nil }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        return unsafeBitCast(keyboard.client.method(for: selector), to: GetKeyboard.self)(keyboard.client, selector, keyboard.id)
    }

    private func writeKeyboard(_ level: Float) {
        guard let keyboard else { return }
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        _ = unsafeBitCast(keyboard.client.method(for: selector), to: SetKeyboard.self)(keyboard.client, selector, level, keyboard.id)
    }

    /// Encodings measured on macOS 27; any difference refuses the keyboard rather than call blind.
    private static func keyboardClient() -> (client: NSObject, id: UInt64)? {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        let expected = [
            "brightnessForKeyboard:": "f24@0:8Q16",
            "setBrightness:forKeyboard:": "B28@0:8f16Q20",
            "copyKeyboardBacklightIDs": "@16@0:8"
        ]
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
              expected.allSatisfy({ name, encoding in
                  class_getInstanceMethod(type, NSSelectorFromString(name))
                      .flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) } == encoding
              }) else { return nil }
        let client = type.init()
        guard let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber],
              let id = ids.first else { return nil }
        return (client, id.uint64Value)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr ? device : nil
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func device(withUID uid: String) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr ? muted != 0 : nil
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
