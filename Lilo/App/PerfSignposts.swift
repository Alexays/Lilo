import Foundation
import OSLog

/// Shared signposters for profiling hot paths in Instruments ("os_signpost" instrument,
/// subsystem fr.arouillard.lilo). Intervals are ~free when no instrument is attached.
enum PerfSignposts {
    static let browserState = OSSignposter(subsystem: "fr.arouillard.lilo", category: "browser-state")
    static let bridge = OSSignposter(subsystem: "fr.arouillard.lilo", category: "bridge")
    /// Wakeups, spawns and disk writes counted by energy measurements (docs/DEBUGGING.md).
    static let energy = OSSignposter(subsystem: "fr.arouillard.lilo", category: "energy")
    /// Extension preparation, loading, worker starts and gap calls, timed by `make ext-bench`.
    static let extensions = OSSignposter(subsystem: "fr.arouillard.lilo", category: "extensions")
}
