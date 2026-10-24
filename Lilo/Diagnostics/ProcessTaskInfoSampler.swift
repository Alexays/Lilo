import Darwin

/// Single `proc_pidinfo(PROC_PIDTASKINFO)` and `proc_pid_rusage` call site, shared by the
/// process-manager metrics panel and the engine discard passes.
enum ProcessTaskInfoSampler {
    static func taskInfo(pid: Int) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = proc_pidinfo(
            Int32(pid),
            PROC_PIDTASKINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_taskinfo>.size)
        )
        return size == Int32(MemoryLayout<proc_taskinfo>.size) ? info : nil
    }

    /// Activity Monitor's figure: unlike the resident size it keeps counting compressed and swapped
    /// pages, so it does not collapse under the memory pressure the discard passes react to.
    static func physicalFootprint(pid: Int) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(Int32(pid), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// `pti_total_user`/`pti_total_system` count Mach ticks, which are not nanoseconds on Apple silicon.
    static func cpuNanoseconds(_ info: proc_taskinfo) -> UInt64 {
        (info.pti_total_user + info.pti_total_system) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()
}
