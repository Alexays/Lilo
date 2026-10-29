import Foundation

/// Sends each extension exactly the `runtime` events Chrome sends per lifecycle transition, waking its worker as needed. Lilo sends
/// onInstalled/onStartup itself: WebKit picks them by load timing and sometimes drops an update (runtime.ts diverts WebKit's own).
@MainActor
final class ExtensionLifecycle {
    /// The worker's channel to Lilo.
    enum Worker: Equatable {
        case stopped
        case running
        /// It let its channel go, and WebKit unloads it at its next idle check.
        case idle
    }

    /// An extension without a state is not loaded: not installed, failed to load, or torn down.
    enum State: Equatable {
        /// Installed but not loaded. `updatedFrom` is the version an update applied meanwhile replaced,
        /// which its next load reports in onInstalled.
        case disabled(updatedFrom: String?)
        case loaded(Worker)
        /// Loaded with a running worker that heard of `to` through onUpdateAvailable: the update applies
        /// once the worker stops, as Chrome delays the update of an extension in use.
        case updating(from: String, to: String)
    }

    /// What a load is, which decides what Chrome tells the extension.
    enum Load: Equatable {
        case install
        case enable
        case update(from: String)
        /// The launch restore.
        case startup
        /// The same extension again, after an internal unload: Chrome says nothing.
        case reload
    }

    private(set) var states: [String: State] = [:]

    private let profileId: UUID
    private let gapEvents: GapEvents
    private let backgrounds: BackgroundSupervisor
    private let settings: () -> SettingsStore?
    /// Applies the update an `updating` extension waits for, from the version it replaces.
    private let applyUpdate: (_ extensionId: String, _ from: String) -> Void

    init(
        profileId: UUID,
        gapEvents: GapEvents,
        backgrounds: BackgroundSupervisor,
        settings: @escaping () -> SettingsStore?,
        applyUpdate: @escaping (String, String) -> Void
    ) {
        self.profileId = profileId
        self.gapEvents = gapEvents
        self.backgrounds = backgrounds
        self.settings = settings
        self.applyUpdate = applyUpdate
    }

    func state(of extensionId: String) -> State? {
        states[extensionId]
    }

    /// The worker of a loaded extension; nil when the extension is not loaded.
    func worker(of extensionId: String) -> Worker? {
        switch states[extensionId] {
        case .loaded(let worker): worker
        case .updating: .running
        case .disabled, nil: nil
        }
    }

    // MARK: - Transitions

    /// The launch restore read the installed records: the disabled ones keep what an update applied
    /// while they were disabled replaced.
    func restoreDisabled(_ extensionIds: [String]) {
        for id in extensionIds {
            states[id] = .disabled(updatedFrom: settings()?.get(updatedFromKey(id)))
        }
    }

    /// WebKit loaded the extension's context; its worker is stopped until WebKit starts it. `storedVersion`
    /// is the installed record's, nil for a new install.
    func loaded(_ extensionId: String, _ load: Load, version: String?, storedVersion: String?, hasBackground: Bool, preparationDegraded: Bool) {
        let previous = states.updateValue(.loaded(.stopped), forKey: extensionId)
        restoreReportedListeners(extensionId, version: version)
        backgrounds.started(extensionId, preparationDegraded: preparationDegraded)
        var updatedFrom = storedVersion.flatMap { $0 != version ? $0 : nil }
        if case .disabled(let from) = previous {
            updatedFrom = updatedFrom ?? from
            if from != nil { settings()?.remove(updatedFromKey(extensionId)) }
        }
        // WebKit starts a new or updated worker itself.
        let details: [String: Any]?, startsItself: Bool
        switch load {
        case .install: (details, startsItself) = (["reason": "install"], true)
        case .enable: (details, startsItself) = (["reason": "enable"], false)
        case .update(let from): (details, startsItself) = (["reason": "update", "previousVersion": from], true)
        case .startup: (details, startsItself) = (["reason": "startup"], false)
        case .reload: (details, startsItself) = (nil, false)
        }
        if hasBackground {
            if load == .install {
                gapEvents.emit("runtime", "onInstalled", args: [["reason": "install"]], to: [extensionId], wakes: false)
            } else if let updatedFrom {
                gapEvents.emit("runtime", "onInstalled", args: [["reason": "update", "previousVersion": updatedFrom]], to: [extensionId])
            }
            if load == .startup { gapEvents.emit("runtime", "onStartup", args: [], to: [extensionId]) }
        }
        // At launch only a worker whose listeners are known hears it, as Chrome wakes only listeners:
        // waking every other worker would cost each launch.
        guard let details, load != .startup || gapEvents.reportedListeners(of: extensionId) != nil else { return }
        if load == .enable { gapEvents.emit("runtime", "onEnabled", args: [], to: [extensionId]) }
        gapEvents.emit("runtime", "onExtensionLoaded", args: [details], to: [extensionId], wakes: !startsItself)
    }

    /// The extension's context left WebKit, and its worker's channel with it. `disabled` keeps it
    /// listed as installed; `purge` drops the events its worker has not received, as a disable does.
    func unloaded(_ extensionId: String, disabled: Bool, purge: Bool) {
        let previous = states.removeValue(forKey: extensionId)
        // The unloaded worker is gone: what comes next waits for the worker of the next load.
        gapEvents.forget(extensionId, purge: purge)
        backgrounds.stopped(extensionId)
        if disabled {
            let updatedFrom: String? = if case .disabled(let from) = previous { from } else { nil }
            states[extensionId] = .disabled(updatedFrom: updatedFrom)
        }
        // A disable stops the worker in use, which lets its update apply.
        if purge, case .updating(let from, _) = previous { applyUpdate(extensionId, from) }
    }

    /// The extension and what Lilo keeps of its lifecycle go.
    func uninstalled(_ extensionId: String) {
        states[extensionId] = nil
        gapEvents.forget(extensionId, purge: true)
        backgrounds.stopped(extensionId)
        settings()?.remove(listenersKey(extensionId))
        settings()?.remove(updatedFromKey(extensionId))
    }

    /// The worker opened, idly closed or lost its channel. A worker that stops lets a waiting update apply.
    func workerChannel(_ extensionId: String, _ channel: GapEvents.WorkerChannel) {
        // An unload is the `unloaded` transition, which already left the state.
        guard channel != .unloaded, let state = states[extensionId] else { return }
        let worker: Worker = switch channel {
        case .open: .running
        case .idle: .idle
        case .lost, .unloaded: .stopped
        }
        switch state {
        case .disabled:
            return
        case .updating(let from, _) where worker != .running:
            states[extensionId] = .loaded(worker)
            backgrounds.workerChannel(extensionId, channel, instance: gapEvents.workerInstance(of: extensionId))
            applyUpdate(extensionId, from)
        case .updating:
            backgrounds.workerChannel(extensionId, channel, instance: gapEvents.workerInstance(of: extensionId))
        case .loaded:
            states[extensionId] = .loaded(worker)
            backgrounds.workerChannel(extensionId, channel, instance: gapEvents.workerInstance(of: extensionId))
        }
    }

    /// An event waits for the worker of a loaded extension without its channel: it is started, or
    /// told to reconnect.
    func wake(_ extensionId: String) {
        guard let worker = worker(of: extensionId), worker != .running else { return }
        backgrounds.wake(extensionId)
    }

    /// A newer version was found. An extension whose worker runs hears onUpdateAvailable, once per
    /// version, and updates once the worker stops; true when it waits for that.
    func updateFound(_ extensionId: String, from current: String, to version: String, manifest: [String: Any]) -> Bool {
        guard worker(of: extensionId) == .running else { return false }
        if states[extensionId] != .updating(from: current, to: version) {
            states[extensionId] = .updating(from: current, to: version)
            gapEvents.emit("runtime", "onUpdateAvailable", args: [manifest], to: [extensionId])
        }
        return true
    }

    /// An update was applied to the files of a disabled extension: its next load reports the version
    /// it had before the first such update.
    func updatedWhileDisabled(_ extensionId: String, from current: String) {
        guard case .disabled(nil) = states[extensionId] ?? .disabled(updatedFrom: nil) else { return }
        states[extensionId] = .disabled(updatedFrom: current)
        settings()?.set(updatedFromKey(extensionId), value: current)
    }

    // MARK: - Listeners

    /// Records events the worker listens to, or, `removed`, no longer listens to. Its first report, sent once
    /// its script has run, turns on filtering; they are kept across launches, as Chrome keeps a worker's
    /// listeners: a stopped worker wakes only for what it listens to. A new version reports its own.
    func listen(_ events: [String], extensionId: String, removed: Bool = false, version: String?) {
        guard gapEvents.listen(events, extensionId: extensionId, removed: removed),
              let reported = gapEvents.reportedListeners(of: extensionId) else { return }
        settings()?.set(listenersKey(extensionId), value: ([version ?? ""] + reported.sorted()).joined(separator: "\n"))
    }

    /// The listeners the worker of this version reported in an earlier launch.
    private func restoreReportedListeners(_ extensionId: String, version: String?) {
        guard let saved = settings()?.get(listenersKey(extensionId))?.components(separatedBy: "\n"),
              saved.first == version ?? "" else { return }
        gapEvents.listen(Array(saved.dropFirst()), extensionId: extensionId)
    }

    private func listenersKey(_ extensionId: String) -> String {
        "extensionWorkerListeners.\(profileId.uuidString).\(extensionId)"
    }

    private func updatedFromKey(_ extensionId: String) -> String {
        "extensionUpdatedFrom.\(profileId.uuidString).\(extensionId)"
    }
}
