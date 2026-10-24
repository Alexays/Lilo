import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

/// The real machine. The power calls are exported by IOKit without a header: resolved once, a
/// missing one makes its call fail.
final class SystemPowerBackend: PowerBackend {
    private typealias SetSystemPowerSetting = @convention(c) (CFString, CFTypeRef) -> IOReturn
    private typealias CopyPMPreferences = @convention(c) () -> Unmanaged<CFMutableDictionary>?
    private typealias SetPMPreferences = @convention(c) (CFDictionary) -> IOReturn

    private let setSystemPowerSetting: SetSystemPowerSetting?
    private let copyPMPreferences: CopyPMPreferences?
    private let setPMPreferences: SetPMPreferences?

    init() {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        setSystemPowerSetting = dlsym(iokit, "IOPMSetSystemPowerSetting").map { unsafeBitCast($0, to: SetSystemPowerSetting.self) }
        copyPMPreferences = dlsym(iokit, "IOPMCopyPMPreferences").map { unsafeBitCast($0, to: CopyPMPreferences.self) }
        setPMPreferences = dlsym(iokit, "IOPMSetPMPreferences").map { unsafeBitCast($0, to: SetPMPreferences.self) }
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        setSystemPowerSetting?("SleepDisabled" as CFString, disabled ? kCFBooleanTrue : kCFBooleanFalse) == kIOReturnSuccess
    }

    /// Kept per power source ("AC Power", "Battery Power"), as `pmset -a lowpowermode` writes it.
    func lowPowerMode() -> Bool? {
        guard let preferences = copyPMPreferences?()?.takeRetainedValue() as? [String: Any] else { return nil }
        return preferences.values.contains { (($0 as? [String: Any])?["LowPowerMode"] as? Int ?? 0) != 0 }
    }

    func setLowPowerMode(_ on: Bool) -> Bool {
        guard var preferences = copyPMPreferences?()?.takeRetainedValue() as? [String: Any], let setPMPreferences else { return false }
        for (source, value) in preferences {
            guard var settings = value as? [String: Any] else { continue }
            settings["LowPowerMode"] = on ? 1 : 0
            preferences[source] = settings
        }
        return setPMPreferences(preferences as CFDictionary) == kIOReturnSuccess
    }

    func process(_ pid: pid_t) -> (start: UInt64, uid: uid_t, stopped: Bool)? {
        Self.info(pid).map { ($0.pbi_start_tvsec * 1_000_000 + $0.pbi_start_tvusec, $0.pbi_uid, $0.pbi_status == UInt32(SSTOP)) }
    }

    static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    func send(_ signal: Int32, to pid: pid_t) { kill(pid, signal) }

    /// The root domain says when a closed lid would sleep the Mac: not with an external display.
    func sleepIfLidClosed() {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(rootDomain) }
        func flag(_ key: String) -> Bool {
            (IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
        }
        guard flag("AppleClamshellState"), flag("AppleClamshellCausesSleep") else { return }
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        defer { IOServiceClose(port) }
        IOPMSleepSystem(port)
    }
}
