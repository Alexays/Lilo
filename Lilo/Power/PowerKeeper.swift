import Foundation
import OSLog
import UserNotifications

/// What the lid does to the machine while Lilo holds it awake; a fake in tests.
@MainActor
protocol LidActions: AnyObject {
    /// Reads the user's brightness while the lid is open, before a close dims the panel.
    func sampleBrightness()
    func lidClosed(helper: PowerHelperProtocol, settings: PowerKeeper.Settings)
    func lidOpened(helper: PowerHelperProtocol)
}

/// Keeps the Mac awake while a terminal command works: an idle-sleep assertion with the lid open,
/// and, in the lid-closed mode, the root helper's sleep guard with its lid actions and floors.
@MainActor
final class PowerKeeper {
    struct Settings: Equatable {
        var preventSleep: Bool
        var lidClosed: Bool
        var batteryFloor: Int
        var maxAwake: TimeInterval
        var freezeApps: Bool
        var neverFreeze: [String]

        init(get: (String) -> String?) {
            preventSleep = get("terminalPreventSleep") != "false"
            lidClosed = get("terminalLidClosed") == "true"
            batteryFloor = get("terminalLidBatteryFloor").flatMap(Int.init) ?? 20
            maxAwake = (get("terminalLidMaxHours").flatMap(Double.init) ?? 8) * 3600
            freezeApps = get("terminalLidFreezeApps") != "false"
            neverFreeze = get("terminalLidNeverFreeze")
                .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? PowerKeeper.defaultNeverFreeze
        }
    }

    struct State: Equatable {
        /// Tab ids of the terminals whose command keeps the Mac awake.
        var working = Set<UUID>()
        var keepsAwake = false
        var holdsLidClosed = false
        var helperStatus = "notRegistered"
    }

    /// Apps an agent often needs while it works; each id is checked against the installed app.
    nonisolated static let defaultNeverFreeze = [
        "com.docker.docker", "com.electron.dockerdesktop", "dev.kdrag0n.MacVirt", "com.postgresapp.Postgres2",
        "com.ollama.ollama", "com.electron.ollama", "ai.elementlabs.lmstudio", "io.tailscale.ipn.macsys",
        "io.tailscale.ipn.macos", "com.1password.1password"
    ]

    var onChange: ((State) -> Void)?
    private(set) var state = State()
    private(set) var settings = Settings(get: { _ in nil })

    private let quietLimit: TimeInterval
    private let sampleInterval: TimeInterval
    private let makeLink: () -> PowerHelperLink?
    private let installer: PowerHelperInstaller
    private let notify: (String, String) -> Void
    private var makeLidActions: (() -> LidActions)?
    private var lidActions: LidActions?

    private var working = Set<UUID>()
    private var awaitingSince: [UUID: Date] = [:]
    private var forced = Set<UUID>()
    private var quietSince: [UUID: Date] = [:]
    private var expiry: DispatchWorkItem?
    private var activity: NSObjectProtocol?
    private var helperStatus = "notRegistered"
    private var link: PowerHelperLink?
    /// The helper answered that sleep is off: until then nothing is reported held nor applied.
    private var holdConfirmed = false
    /// The link was refused (not approved, signature): no retry until the status is read again.
    private var helperUnavailable = false
    private var lidActionsApplied = false
    private var lowPowerRequested = false
    /// While snoozed: the commands working at the time. A command outside it ends the snooze.
    private var snoozedWorking: Set<UUID>?
    private var capReached = false
    private var capTimer: DispatchWorkItem?
    private var holdStartedAt: Date?
    private var sampler: Timer?
    private var lidClosed = false
    private var onBattery = false
    private var batteryPercent: Int?
    private var unreadableReadings = 0
    private var thermal = ProcessInfo.ThermalState.nominal
    private var closedPeriod: (battery: Int?, finished: Int)?
    private var monitorsSystem = false
    private var lidObserver: LidObserver?
    private var powerMonitor: PowerSourceMonitor?
    private var thermalObserver: NSObjectProtocol?

    init(
        quietLimit: TimeInterval = 300,
        sampleInterval: TimeInterval = 30,
        makeLink: @escaping () -> PowerHelperLink? = { XPCPowerHelperLink() },
        installer: PowerHelperInstaller = SMAppServiceInstaller(),
        notify: @escaping (String, String) -> Void = PowerKeeper.postNotification
    ) {
        self.quietLimit = quietLimit
        self.sampleInterval = sampleInterval
        self.makeLink = makeLink
        self.installer = installer
        self.notify = notify
    }

    /// Wires the lid actions and, with `monitorSystem`, the real lid, battery and heat monitors.
    /// Neither exists before the lid-closed mode is on, and the monitors stop when it goes off.
    func start(lidActions: @escaping () -> LidActions, monitorSystem: Bool = false) {
        makeLidActions = lidActions
        monitorsSystem = monitorSystem
        // Read once even with the mode off: Settings greys out the toggle on builds that can't run the helper.
        // It checks the app's own signature, so it waits until launch is done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !settings.lidClosed else { return }
            helperStatus = installer.status
            update()
        }
    }

    func apply(_ settings: Settings) {
        let previous = self.settings
        self.settings = settings
        helperUnavailable = false
        if settings.lidClosed {
            // Built at once, not at the first hold: it puts back what a crash with the lid closed left.
            if lidActions == nil {
                PerfSignposts.energy.emitEvent("lidActionsBuilt")
                lidActions = makeLidActions?()
            }
            helperStatus = installer.status
            // Approved or waiting for approval stays as is; an ad-hoc build can never run the helper.
            // "notFound" is what macOS reports once the app was replaced: registering again finds it.
            if helperStatus == "notRegistered" || helperStatus == "notFound" {
                installer.register()
                helperStatus = installer.status
            }
        }
        if monitorsSystem, settings.lidClosed != (lidObserver != nil) { monitorSystem(settings.lidClosed) }
        if !settings.lidClosed, previous.lidClosed { unregisterWhenReleased() }
        if settings.maxAwake != previous.maxAwake, link != nil { armCap() }
        update()
    }

    /// Reads the helper's status again: the user approves it in System Settings, outside Lilo.
    /// Only the lid-closed mode uses the helper.
    func refreshHelperStatus() {
        guard settings.lidClosed else { return }
        helperStatus = installer.status
        helperUnavailable = false
        update()
    }

    /// Sends the current state even when unchanged, for a window that just asked for it.
    func republish() {
        onChange?(state)
    }

    // MARK: Terminals

    func terminalStatusChanged(_ id: UUID, _ status: TerminalSession.Status) {
        if let since = status.awaitingInputSince { awaitingSince[id] = awaitingSince[id] ?? since } else { awaitingSince[id] = nil }
        let running = status.state == .busy && status.awaitingInputSince == nil
        if !running {
            if working.contains(id), status.state != .busy { closedPeriod?.finished += 1 }
            forced.remove(id)
            quietSince[id] = nil
            working.remove(id)
            snoozedWorking?.remove(id)
        } else if status.printing {
            quietSince[id] = nil
            working.insert(id)
        } else {
            // A quiet interactive prompt (an agent between turns) waits for the user: no grace period.
            if quietSince[id] == nil { quietSince[id] = status.bracketedPaste ? .distantPast : Date() }
            working.insert(id)
            expireQuietCommands()
        }
        update()
    }

    /// A terminal closed, or a browser agent disconnected: its hold ends now, not after the quiet limit.
    func terminalEnded(_ id: UUID) {
        if working.contains(id) { closedPeriod?.finished += 1 }
        working.remove(id)
        awaitingSince[id] = nil
        forced.remove(id)
        quietSince[id] = nil
        snoozedWorking?.remove(id)
        update()
    }

    /// A browser agent's tool call: it works like a quiet command, for the quiet limit after its last call.
    func browserAgentWorked(_ id: UUID) {
        quietSince[id] = Date()
        working.insert(id)
        expireQuietCommands()
        update()
    }

    /// For a long silent command: it counts as working until it ends, whatever it prints.
    func keepAwakeUntilDone(_ id: UUID) {
        forced.insert(id)
        if quietSince[id] != nil { working.insert(id) }
        update()
    }

    /// Gives sleep back until a command that is not working now starts working.
    func snooze() {
        snoozedWorking = working
        update()
    }

    // Removes the commands quiet for longer than the limit, and arms one timer for the next.
    private func expireQuietCommands() {
        expiry?.cancel()
        let now = Date()
        var next: Date?
        for (id, since) in quietSince where !forced.contains(id) {
            let deadline = since.addingTimeInterval(quietLimit)
            if deadline <= now { working.remove(id) } else { next = min(next ?? deadline, deadline) }
        }
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.expireQuietCommands()
            self?.update()
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now), execute: work)
    }

    // MARK: System events

    // The lid, battery and heat only decide the lid-closed hold: nothing is watched without it.
    private func monitorSystem(_ on: Bool) {
        PerfSignposts.energy.emitEvent("powerMonitors", "\(on ? "start" : "stop")")
        guard on else {
            lidObserver = nil
            powerMonitor = nil
            if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
            thermalObserver = nil
            return
        }
        let lid = LidObserver()
        lid.onChange = { [weak self] in self?.lidChanged(closed: $0) }
        lidClosed = lid.isClosed
        lidObserver = lid
        let power = PowerSourceMonitor()
        power.onChange = { [weak self, unowned power] in self?.powerChanged(onBattery: power.onBattery, percent: power.percent) }
        onBattery = power.onBattery
        batteryPercent = power.percent
        powerMonitor = power
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged(ProcessInfo.processInfo.thermalState) }
        }
        thermal = ProcessInfo.processInfo.thermalState
    }

    func lidChanged(closed: Bool) {
        guard closed != lidClosed else { return }
        lidClosed = closed
        if closed, holdConfirmed {
            closedPeriod = (batteryPercent, 0)
        } else if !closed, let period = closedPeriod {
            closedPeriod = nil
            summarize(period)
        }
        update()
    }

    func powerChanged(onBattery: Bool, percent: Int?) {
        let wasLow = batteryTooLow
        self.onBattery = onBattery
        batteryPercent = percent
        unreadableReadings = onBattery && percent == nil ? unreadableReadings + 1 : 0
        if batteryTooLow, !wasLow, link != nil {
            notify("Sleep is back on".localized, String(format: "The battery is below %d%%.".localized, settings.batteryFloor))
        }
        update()
    }

    func thermalChanged(_ thermal: ProcessInfo.ThermalState) {
        let wasCritical = self.thermal == .critical
        self.thermal = thermal
        if thermal == .critical, !wasCritical, link != nil {
            notify("Sleep is back on".localized, "The Mac is too hot.".localized)
        }
        update()
    }

    private var batteryTooLow: Bool {
        guard onBattery else { return false }
        return batteryPercent.map { $0 < settings.batteryFloor } ?? (unreadableReadings >= 2)
    }

    // MARK: Holding

    private func update() {
        if working.isEmpty {
            capReached = false
            helperUnavailable = false
        }
        if let snoozed = snoozedWorking, !working.isSubset(of: snoozed) { snoozedWorking = nil }
        let keepAwake = settings.preventSleep && !working.isEmpty && snoozedWorking == nil
        if keepAwake, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "A terminal command is working")
        } else if !keepAwake, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        let holdLid = keepAwake && settings.lidClosed && helperStatus == "enabled" && !helperUnavailable
            && !capReached && !batteryTooLow && thermal != .critical
        if holdLid, link == nil { startHolding() } else if !holdLid, link != nil { stopHolding() }
        if let link, holdConfirmed {
            if lidClosed != lidActionsApplied {
                lidActionsApplied = lidClosed
                if lidClosed {
                    lidActions?.lidClosed(helper: link.helper, settings: settings)
                } else {
                    lidActions?.lidOpened(helper: link.helper)
                    lidActions?.sampleBrightness()
                }
            }
            let lowPower = lidClosed || thermal == .serious
            if lowPower != lowPowerRequested {
                lowPowerRequested = lowPower
                link.helper.setLowPowerMode(lowPower) { _ in }
            }
        }
        syncSampler()
        publish(State(working: working, keepsAwake: keepAwake, holdsLidClosed: link != nil && holdConfirmed, helperStatus: helperStatus))
    }

    private func startHolding() {
        guard let link = makeLink() else {
            helperUnavailable = true
            return
        }
        self.link = link
        holdConfirmed = false
        holdStartedAt = Date()
        link.onLost = { [weak self, weak link] invalidated in
            guard let self, let link, self.link === link else { return }
            drop(link)
            if invalidated { helperUnavailable = true }
            update()
        }
        link.helper.holdAwake { [weak self, weak link] held in
            Self.onMain {
                guard let self, let link, self.link === link else { return }
                if held {
                    self.holdConfirmed = true
                    if !self.lidClosed { self.lidActions?.sampleBrightness() }
                } else {
                    self.drop(link)
                    self.helperUnavailable = true
                }
                self.update()
            }
        }
        armCap()
    }

    /// Detaches a link the helper no longer serves, putting back what Lilo itself changed.
    private func drop(_ link: PowerHelperLink) {
        if lidActionsApplied { lidActions?.lidOpened(helper: link.helper) }
        link.onLost = nil
        link.close()
        detach()
    }

    private func detach() {
        link = nil
        holdConfirmed = false
        lidActionsApplied = false
        lowPowerRequested = false
        capTimer?.cancel()
        capTimer = nil
        holdStartedAt = nil
    }

    /// Gives everything back, then closes the link once the helper confirmed it, so an unregister
    /// that follows cannot stop the helper before it undid the claims. `done` gets the number of
    /// other clients still connected.
    private func stopHolding(then done: ((Int) -> Void)? = nil) {
        guard let link else { return }
        if lidActionsApplied { lidActions?.lidOpened(helper: link.helper) }
        link.onLost = nil
        detach()
        release(link, then: done)
    }

    private func release(_ link: PowerHelperLink, then done: ((Int) -> Void)?) {
        var finished = false
        let finish: @MainActor (Int?) -> Void = { others in
            guard !finished else { return }
            finished = true
            link.close()
            // A helper that never answers counts as alone: nothing else can be told apart.
            done?(others ?? 0)
        }
        link.helper.releaseAll { others in Self.onMain { finish(others) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { finish(nil) } }
    }

    // Another Lilo may still use the helper: it is only removed once none is connected.
    private func unregisterWhenReleased() {
        let unregister: (Int) -> Void = { [weak self] others in
            // The mode may have been turned back on while the helper answered.
            guard let self, others == 0, !settings.lidClosed else { return }
            installer.unregister()
            helperStatus = installer.status
            update()
        }
        if link != nil {
            stopHolding(then: unregister)
        } else if helperStatus == "enabled", let probe = makeLink() {
            release(probe, then: unregister)
        } else {
            installer.unregister()
            helperStatus = installer.status
        }
    }

    private func armCap() {
        capTimer?.cancel()
        guard let start = holdStartedAt else { return }
        let cap = DispatchWorkItem { [weak self] in
            guard let self else { return }
            capReached = true
            notify("Sleep is back on".localized, "Commands kept the Mac awake for the maximum duration.".localized)
            update()
        }
        capTimer = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, settings.maxAwake - Date().timeIntervalSince(start)), execute: cap)
    }

    // The brightness to restore is the user's, read with the lid open while held, not the value
    // a closing lid's light sensor has already dimmed.
    private func syncSampler() {
        let wanted = link != nil && holdConfirmed && !lidClosed
        if wanted, sampler == nil {
            sampler = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.lidActions?.sampleBrightness() }
            }
            sampler?.tolerance = sampleInterval / 10
        } else if !wanted, let sampler {
            sampler.invalidate()
            self.sampler = nil
        }
    }

    private func summarize(_ period: (battery: Int?, finished: Int)) {
        var parts = [String(format: "%d commands finished".localized, period.finished)]
        if let oldest = awaitingSince.values.min() {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = [.hour, .minute]
            formatter.maximumUnitCount = 2
            let waited = formatter.string(from: max(60, Date().timeIntervalSince(oldest))) ?? ""
            parts.append(String(format: "%d wait for your answer, the oldest for %@".localized, awaitingSince.count, waited))
        }
        if let before = period.battery, let after = batteryPercent {
            parts.append(String(format: "battery from %d%% to %d%%".localized, before, after))
        }
        notify("While the lid was closed".localized, parts.joined(separator: ", "))
    }

    private func publish(_ new: State) {
        guard new != state else { return }
        state = new
        onChange?(new)
    }

    /// XPC replies arrive on a connection queue; one already on the main thread runs at once.
    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    nonisolated static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.requestAuthorizationAndAdd(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
