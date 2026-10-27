import Foundation
import OSLog

/// Shared signposters for profiling hot paths in Instruments ("os_signpost" instrument,
/// subsystem fr.arouillard.lilo), also captured by `PerfRecorder` while a session is recorded.
/// Intervals are ~free when neither is listening.
enum PerfSignposts {
    static let browserState = PerfSignposter(category: "browser-state")
    static let bridge = PerfSignposter(category: "bridge")
    /// Wakeups, spawns and disk writes counted by energy measurements (docs/DEBUGGING.md).
    static let energy = PerfSignposter(category: "energy")
    /// Extension preparation, loading, worker starts and gap calls, timed by `make ext-bench`.
    static let extensions = PerfSignposter(category: "extensions")
    /// Page loads, from provisional start to finish.
    static let navigation = PerfSignposter(category: "navigation")
    /// What the person did (menu item, shortcut), never what it applied to.
    static let input = PerfSignposter(category: "input")
}

struct PerfSignpostState {
    let state: OSSignpostIntervalState
    let id: OSSignpostID
}

/// `OSSignposter` with the same call shape. Details are plain strings logged as public: they must
/// never carry a URL, title, path or name the person typed.
struct PerfSignposter: Sendable {
    let category: StaticString
    let signposter: OSSignposter

    init(category: StaticString) {
        self.category = category
        signposter = OSSignposter(subsystem: "fr.arouillard.lilo", category: "\(category)")
    }

    var isEnabled: Bool { signposter.isEnabled || PerfRecorder.isRecording }

    func makeSignpostID() -> OSSignpostID { signposter.makeSignpostID() }

    func makeSignpostID(from object: AnyObject) -> OSSignpostID { signposter.makeSignpostID(from: object) }

    func emitEvent(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        let recording = PerfRecorder.isRecording
        guard recording || signposter.isEnabled else { return }
        let text = detail()
        signposter.emitEvent(name, "\(text, privacy: .public)")
        if recording { PerfRecorder.append(.event, category, name, 0, text) }
    }

    func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive, _ detail: @autoclosure () -> String = "") -> PerfSignpostState {
        let recording = PerfRecorder.isRecording
        guard recording || signposter.isEnabled else { return PerfSignpostState(state: signposter.beginInterval(name, id: id), id: id) }
        let text = detail()
        if recording { PerfRecorder.append(.begin, category, name, id.rawValue, text) }
        return PerfSignpostState(state: signposter.beginInterval(name, id: id, "\(text, privacy: .public)"), id: id)
    }

    func endInterval(_ name: StaticString, _ state: PerfSignpostState, _ detail: @autoclosure () -> String = "") {
        let recording = PerfRecorder.isRecording
        guard recording || signposter.isEnabled else { return signposter.endInterval(name, state.state) }
        let text = detail()
        if recording { PerfRecorder.append(.end, category, name, state.id.rawValue, text) }
        signposter.endInterval(name, state.state, "\(text, privacy: .public)")
    }

    /// Ends an interval begun in another callback, matched by the id it was begun with.
    func endInterval(_ name: StaticString, id: OSSignpostID, _ detail: @autoclosure () -> String = "") {
        endInterval(name, PerfSignpostState(state: .beginState(id: id), id: id), detail())
    }
}
