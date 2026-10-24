import AppKit
import IOKit.ps

/// Discards hidden-space engines when the app backgrounds, memory is tight or the system is
/// power-constrained, and cancels pending trims when the app returns to the foreground.
@MainActor
final class HiddenSpaceLifecycleController {
    private let store: BrowserStateStore
    private(set) var config: LifecyclePolicyConfig
    private let discardEngine: (WKWebViewTab) -> Any?
    private let syncActiveState: () -> Void
    /// Runs on the same triggers as the hidden-space trim plus after tab activations, so the visible
    /// space also obeys a live-engine budget.
    private let trimActiveSpaceEngines: (TabLifecycleCoordinator.Policy, Int?) -> Void
    /// Live probe for "the system wants us to spend less energy" (Low Power Mode / serious thermal).
    /// Injected so tests can force the constrained state without touching real `ProcessInfo`.
    private let isPowerConstrained: () -> Bool
    /// Sums live-engine WebContent footprint for the idle-sweep footprint ceiling. Injected so tests
    /// can force an over/under-ceiling sum without spawning real web processes.
    private let footprintSampler: @MainActor ([UUID: WKWebViewTab]) -> [UUID: UInt64]
    private let cpuSampler = WebContentCPUSampler()
    private var busyTabIdsAtLastSweep: Set<UUID> = []

    /// Work items run synchronously on the main queue, so a cancel() before they fire is final.
    private var pendingTrimWorkItem: DispatchWorkItem?
    private var pendingActiveSpaceTrimWorkItem: DispatchWorkItem?
    /// Debounces *entry* into constrained power (see `constrainedPowerGracePeriod`); exit is immediate.
    private var pendingConstrainedPowerWorkItem: DispatchWorkItem?
    private(set) var pendingTrimProtectedSpaceId: UUID?
    /// App activation. Drives the call-window handoff and the warm-pool release; the engine policy
    /// follows `isWindowVisible` instead, since another app taking focus hides nothing.
    private(set) var isForeground = true
    /// Tracks whether the window is considered visible by the occlusion system.
    /// Defaults to true; updated via windowOcclusionChanged(isVisible:).
    private(set) var isWindowVisible = true
    private var foregroundObserver: Any?
    private var backgroundObserver: Any?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var thermalObserver: Any?
    private var powerStateObserver: Any?
    /// Holds an unretained `self` as its context: invalidated in teardown and deinit (thread-safe).
    nonisolated(unsafe) private var powerSourceNotification: CFRunLoopSource?
    private var idleSweepTimer: DispatchSourceTimer?
    /// Keeps suspend/resume balanced on the sweep source: an over-resume crashes.
    private var idleSweepSuspended = false
    /// Footprint-ceiling hysteresis: the sweep skips re-sampling while the live-engine count is
    /// unchanged and the last sampled total sat well under the ceiling (see runIdleSweep).
    private var lastFootprintTotal: UInt64 = 0
    private var lastFootprintEngineCount = -1

    /// Fired on the main actor whenever the constrained-power signal flips. The window controller
    /// forwards it to the engine factory (warm pool) and the chrome UI (decorative animations, blur).
    var onConstrainedPowerChange: ((Bool) -> Void)?
    /// Fired on the main actor when the system signals memory pressure (.warning/.critical), before
    /// the engine trim. The window controller uses it to drop the speculative warm pool.
    var onMemoryPressure: (() -> Void)?
    /// Fired on the main actor when the app resigns active or the window fully occludes. The window
    /// controller schedules the warm pool release: a pre-spawned WebContent process is wasted energy
    /// once nothing has been visible for a while, but a quick app switch keeps it.
    var onBackgrounded: (() -> Void)?
    /// Fired on the main actor when the app returns to the foreground with a visible window
    /// (mirror of onBackgrounded). The window controller re-docks a panel-floated call.
    var onForegrounded: (() -> Void)?
    private(set) var isConstrainedPower = false
    /// Last level the memory pressure source reported: every trim stays tightened until it reads normal.
    private var memoryPressure: DispatchSource.MemoryPressureEvent = .normal
    /// Fired on the main actor when the Mac switches between battery and external power.
    var onBatteryPowerChange: ((Bool) -> Void)?
    private(set) var isOnBatteryPower = false

    /// Low Power Mode or a serious/critical thermal state: both mean "stop spending energy
    /// on anything speculative or decorative".
    static func systemIsPowerConstrained() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// Test surface.
    var hasPendingTrim: Bool { pendingTrimWorkItem != nil }
    var hasPendingActiveSpaceTrim: Bool { pendingActiveSpaceTrimWorkItem != nil }
    var isMonitoringMemoryPressure: Bool { memoryPressureSource != nil }
    var isIdleSweepSuspended: Bool { idleSweepSuspended }

    init(
        store: BrowserStateStore,
        config: LifecyclePolicyConfig,
        discardEngine: @escaping (WKWebViewTab) -> Any?,
        syncActiveState: @escaping () -> Void,
        trimActiveSpaceEngines: @escaping (TabLifecycleCoordinator.Policy, Int?) -> Void = { _, _ in },
        isPowerConstrained: @escaping () -> Bool = { HiddenSpaceLifecycleController.systemIsPowerConstrained() },
        footprintSampler: @escaping @MainActor ([UUID: WKWebViewTab]) -> [UUID: UInt64] = BrowserStateStore.sampleWebContentFootprint
    ) {
        self.store = store
        self.config = config
        self.discardEngine = discardEngine
        self.syncActiveState = syncActiveState
        self.trimActiveSpaceEngines = trimActiveSpaceEngines
        self.isPowerConstrained = isPowerConstrained
        self.footprintSampler = footprintSampler
    }

    deinit {
        // Releasing a suspended dispatch source traps; balance it before the last reference drops
        // (a controller discarded without teardown() may still hold a suspended sweep source).
        if idleSweepSuspended { idleSweepTimer?.resume() }
        if let powerSourceNotification { CFRunLoopSourceInvalidate(powerSourceNotification) }
    }

    func applyConfig(_ newConfig: LifecyclePolicyConfig) {
        config = newConfig
        if idleSweepTimer != nil { cancelIdleSweep(); startIdleSweep() }
    }

    var currentPolicy: TabLifecycleCoordinator.Policy {
        // Occlusion, not app activation: another app's focus leaves this window on screen, and tightening there would cold-reload every tab.
        // The idle sweep keeps running while visible, which bounds memory during a long switch-away.
        isWindowVisible ? .foreground : .background
    }

    /// Tightens a trim's policy and active-space cap to the memory pressure in force.
    private func memoryPressurePlan(
        policy: TabLifecycleCoordinator.Policy,
        cap: Int?
    ) -> (policy: TabLifecycleCoordinator.Policy, cap: Int?) {
        // Critical: hard collapse, hidden spaces fully trimmed and the active space to 1.
        if memoryPressure.contains(.critical) { return (.background, nil) }
        // Warning: the active space stays usable but capped; hidden spaces keep their normal retained set.
        if memoryPressure.contains(.warning) { return (policy, min(cap ?? .max, config.constrainedForegroundEngineBudget)) }
        return (policy, cap)
    }

    func scheduleTrim(
        excluding protectedSpaceId: UUID? = nil,
        delay: TimeInterval = 0.2,
        policy: TabLifecycleCoordinator.Policy? = nil,
        activeBudgetCap: Int? = nil
    ) {
        pendingTrimWorkItem?.cancel()
        pendingTrimProtectedSpaceId = protectedSpaceId
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let protectedSpaceId = self.pendingTrimProtectedSpaceId
                self.pendingTrimWorkItem = nil
                self.pendingTrimProtectedSpaceId = nil
                let plan = self.memoryPressurePlan(policy: policy ?? self.currentPolicy, cap: activeBudgetCap)
                self.store.trimInactiveEngines(
                    excluding: protectedSpaceId,
                    policy: plan.policy,
                    maxRetainedEnginesPerHiddenSpace: self.config.maxNormalRetainedEnginesPerHiddenSpace,
                    maxHiddenSpacesWithRetainedEngines: self.config.maxHiddenSpacesWithNormalRetainedEngines,
                    discardEngine: self.discardEngine,
                    discardThreshold: self.config.discardThreshold
                )
                self.trimActiveSpaceEngines(plan.policy, plan.cap)
                #if DEBUG
                StartupMetrics.trace("lifecycle", self.store.lifecycleDiagnostics().traceMessage)
                #endif
            }
        }
        pendingTrimWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// No hidden space changed after a tab activation, so the full sweep would re-project every inactive
    /// space for nothing. A burst of activations coalesces into one trim.
    func scheduleActiveSpaceTrim(delay: TimeInterval = 2.0) {
        pendingActiveSpaceTrimWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingActiveSpaceTrimWorkItem = nil
                let plan = self.memoryPressurePlan(policy: self.currentPolicy, cap: nil)
                self.trimActiveSpaceEngines(plan.policy, plan.cap)
            }
        }
        pendingActiveSpaceTrimWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func forceTrim() {
        cancelPendingTrim()
        syncActiveState()
        store.trimInactiveEngines(
            excluding: nil,
            policy: .background,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: discardEngine
        )
        trimActiveSpaceEngines(.background, nil)
        #if DEBUG
        StartupMetrics.trace("lifecycle", store.lifecycleDiagnostics().traceMessage)
        #endif
    }

    private func startIdleSweep() {
        guard config.freezeThreshold.isFinite || config.discardThreshold.isFinite else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Generous leeway: the sweep is a housekeeping pass, so the kernel may coalesce it with
        // other wakeups instead of forcing a precise timer fire.
        timer.schedule(deadline: .now() + config.idleSweepInterval, repeating: config.idleSweepInterval, leeway: .seconds(15))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.runIdleSweep() }
        }
        timer.resume()
        idleSweepTimer = timer
        idleSweepSuspended = false
        syncIdleSweepSuspension()   // a (re)start while backgrounded/occluded begins suspended
    }

    /// The sweep only acts under a .foreground policy, so the source is suspended (no periodic
    /// main-queue wakeups) whenever the policy tightens and resumed when it relaxes.
    private func syncIdleSweepSuspension() {
        guard let timer = idleSweepTimer else { return }
        let shouldSuspend = currentPolicy != .foreground
        guard shouldSuspend != idleSweepSuspended else { return }
        idleSweepSuspended = shouldSuspend
        if shouldSuspend { timer.suspend() } else { timer.resume() }
    }

    private func cancelIdleSweep() {
        guard let timer = idleSweepTimer else { return }
        // A suspended source must be resumed before cancel takes effect.
        if idleSweepSuspended {
            timer.resume()
            idleSweepSuspended = false
        }
        timer.cancel()
        idleSweepTimer = nil
    }

    func runIdleSweep() {
        // Only sweep while the window is visible; occlusion already trims hard via policy.
        guard currentPolicy == .foreground else { return }
        // Under constrained power, stop spending energy on speculative retained engines.
        let sweepPolicy = memoryPressurePlan(policy: isConstrainedPower ? .background : .foreground, cap: nil).policy
        store.freezeIdleEngines(freezeThreshold: config.freezeThreshold)
        store.trimInactiveEngines(
            excluding: nil,
            policy: sweepPolicy,
            maxRetainedEnginesPerHiddenSpace: config.maxNormalRetainedEnginesPerHiddenSpace,
            maxHiddenSpacesWithRetainedEngines: config.maxHiddenSpacesWithNormalRetainedEngines,
            discardEngine: discardEngine,
            discardThreshold: config.discardThreshold
        )
        // The active space keeps up to constrainedForegroundEngineBudget engines: a .background trim would
        // collapse it to one and discard the user's other open tabs.
        let activePlan = memoryPressurePlan(policy: .foreground, cap: nil)
        trimActiveSpaceEngines(activePlan.policy, activePlan.cap)
        let physical = ProcessInfo.processInfo.physicalMemory
        let ceiling = max(
            LifecyclePolicyConfig.memoryFootprintCeilingFloorBytes,
            UInt64(Double(physical) * LifecyclePolicyConfig.memoryFootprintCeilingFraction)
        )
        store.discardBusyBackgroundEngines(
            maxCPUPercent: LifecyclePolicyConfig.busyEngineCPUPercent,
            // One tab that grew to an eighth of the ceiling goes without waiting for the total to reach it.
            maxFootprintBytes: ceiling / 8,
            previouslyBusyTabIds: &busyTabIdsAtLastSweep,
            cpuSampler: cpuSampler.sample,
            discardEngine: discardEngine
        )
        // Only the sweep samples the footprint (an SPI call per engine plus a syscall per process), so a quiet steady state skips the pass;
        // the OS memory-pressure source still backstops it.
        let engineCount = store.liveEngineCount
        if engineCount != lastFootprintEngineCount || lastFootprintTotal >= ceiling * 7 / 10 {
            let footprint = store.trimEnginesExceedingFootprintCeiling(
                ceilingBytes: ceiling,
                discardEngine: discardEngine,
                footprintSampler: footprintSampler
            )
            // The hidden spaces could not cover the excess: the visible ones drop their off-screen tabs.
            if footprint.remaining > ceiling { trimActiveSpaceEngines(.foreground, config.constrainedForegroundEngineBudget) }
            lastFootprintTotal = footprint.total
            lastFootprintEngineCount = engineCount
        }
    }

    func setupObservers() {
        isForeground = NSApplication.shared.isActive
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidBecomeActive()
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillResignActive()
            }
        }
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        memoryPressureSource?.setEventHandler { [weak self] in
            // The event's level is only defined inside this handler, so read it before the hop.
            let level = self?.memoryPressureSource?.data ?? .critical
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure(level)
            }
        }
        memoryPressureSource?.resume()

        isConstrainedPower = isPowerConstrained()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reevaluateConstrainedPower()
            }
        }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reevaluateConstrainedPower()
            }
        }
        isOnBatteryPower = Self.systemIsOnBatteryPower()
        // The limited-power notification fires only on an AC/battery switch, not on every
        // percent change like IOPSNotificationCreateRunLoopSource.
        if let source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let controller = Unmanaged<HiddenSpaceLifecycleController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.reevaluateBatteryPower() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceNotification = source
        }
        startIdleSweep()
    }

    static func systemIsOnBatteryPower() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    private func reevaluateBatteryPower() {
        let onBattery = Self.systemIsOnBatteryPower()
        guard onBattery != isOnBatteryPower else { return }
        isOnBatteryPower = onBattery
        onBatteryPowerChange?(onBattery)
    }

    func reevaluateConstrainedPower() {
        let constrained = isPowerConstrained()
        guard constrained || pendingConstrainedPowerWorkItem != nil || isConstrainedPower else { return }
        guard constrained else {
            // Leaving constrained power (or a blip ending mid-grace) applies immediately: relaxing
            // costs nothing, and cancelling the pending entry is what absorbs thermal flapping.
            pendingConstrainedPowerWorkItem?.cancel()
            pendingConstrainedPowerWorkItem = nil
            if isConstrainedPower {
                isConstrainedPower = false
                onConstrainedPowerChange?(false)
            }
            return
        }
        guard !isConstrainedPower, pendingConstrainedPowerWorkItem == nil else { return }
        // The thermal state oscillates every few dozen seconds on a loaded laptop, and adopting each flip
        // would churn the warm pool and schedule a trim per flip. Only a sustained state is adopted.
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingConstrainedPowerWorkItem = nil
                guard self.isPowerConstrained() else { return }   // re-check: the signal may have blipped off
                self.isConstrainedPower = true
                self.onConstrainedPowerChange?(true)
                // Defer to currentPolicy and cap the visible space rather than forcing .background, which would
                // collapse it to a single engine.
                self.scheduleTrim(
                    excluding: nil,
                    delay: 0,
                    policy: nil,
                    activeBudgetCap: self.config.constrainedForegroundEngineBudget
                )
            }
        }
        pendingConstrainedPowerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + config.constrainedPowerGracePeriod, execute: workItem)
    }

    func teardown() {
        cancelPendingTrim()
        cancelPendingActiveSpaceTrim()
        pendingConstrainedPowerWorkItem?.cancel()
        pendingConstrainedPowerWorkItem = nil
        cancelIdleSweep()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if let powerSourceNotification { CFRunLoopSourceInvalidate(powerSourceNotification) }
        powerSourceNotification = nil
        [foregroundObserver, backgroundObserver, thermalObserver, powerStateObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
        foregroundObserver = nil
        backgroundObserver = nil
        thermalObserver = nil
        powerStateObserver = nil
    }

    func handleDidBecomeActive() {
        isForeground = true
        syncIdleSweepSuspension()
        // Only cancel the pending trim when the window is also visible; if it is still occluded
        // the effective policy remains tightened and the scheduled trim should proceed.
        guard isWindowVisible else { return }
        onForegrounded?()
        cancelPendingTrim()
    }

    func handleWillResignActive() {
        isForeground = false
        syncIdleSweepSuspension()
        onBackgrounded?()
        // The trim scheduled below supersedes any queued post-activation active-space trim.
        cancelPendingActiveSpaceTrim()
        // No forced `.background`: the policy is resolved at fire time, so a window still on screen
        // keeps its adaptive budget and only a genuinely hidden one collapses.
        scheduleTrim(delay: self.config.backgroundTrimGracePeriod)
    }

    func handleMemoryPressure(_ level: DispatchSource.MemoryPressureEvent = .critical) {
        memoryPressure = level
        guard level != .normal else { return }
        onMemoryPressure?()
        scheduleTrim(delay: 0)
    }

    /// Syncs `isWindowVisible` (which boots as `true`) once the window is ordered in, so a launch
    /// behind other windows doesn't keep a stale foreground policy. Unlike `windowOcclusionChanged` it
    /// schedules and cancels no trim: a possibly-lagging occlusion read at show time must not queue one.
    func syncWindowVisibility(_ isVisible: Bool) {
        isWindowVisible = isVisible
        syncIdleSweepSuspension()
    }

    /// Called when the window's occlusion state changes. Behaves like the app-background
    /// transition when hidden and like the foreground transition when visible: occlusion alone
    /// decides the engine policy, app activation only drives the call-window handoff.
    func windowOcclusionChanged(isVisible: Bool) {
        isWindowVisible = isVisible
        syncIdleSweepSuspension()
        if isVisible {
            // A window back on screen keeps its engines whether or not the app is frontmost, so the
            // collapse queued while it was hidden has to go; only the call-window handoff waits for
            // the app itself to come back.
            cancelPendingTrim()
            guard isForeground else { return }
            onForegrounded?()
        } else {
            // Same reasoning as handleWillResignActive: an occlusion mid-debounce must not turn the
            // post-activation active-space trim into a background collapse of the still-open tabs.
            onBackgrounded?()
            cancelPendingActiveSpaceTrim()
            scheduleTrim(delay: self.config.backgroundTrimGracePeriod, policy: .background)
        }
    }

    private func cancelPendingTrim() {
        pendingTrimWorkItem?.cancel()
        pendingTrimWorkItem = nil
        pendingTrimProtectedSpaceId = nil
    }

    private func cancelPendingActiveSpaceTrim() {
        pendingActiveSpaceTrimWorkItem?.cancel()
        pendingActiveSpaceTrimWorkItem = nil
    }
}

/// CPU share of each engine's content process since the previous `sample` call, and its physical
/// footprint. Tabs sharing a process all report that process's figures.
@MainActor
final class WebContentCPUSampler {
    struct EngineUsage: Equatable {
        let pid: Int
        let percent: Double
        var footprint: UInt64 = 0
    }

    private var previous: [Int: (uptime: UInt64, cpu: UInt64)] = [:]

    func sample(_ engines: [UUID: WKWebViewTab]) -> [UUID: EngineUsage] {
        let now = DispatchTime.now().uptimeNanoseconds
        var pidByTab: [UUID: Int] = [:]
        for (tabId, engine) in engines {
            if let pid = WebViewPrivateAccessors(engine.wkWebView).pid("_webProcessIdentifier") { pidByTab[tabId] = pid }
        }
        var next: [Int: (uptime: UInt64, cpu: UInt64)] = [:]
        var usageByPid: [Int: EngineUsage] = [:]
        for pid in Set(pidByTab.values) {
            guard let info = ProcessTaskInfoSampler.taskInfo(pid: pid) else { continue }
            let cpu = ProcessTaskInfoSampler.cpuNanoseconds(info)
            next[pid] = (now, cpu)
            // No baseline for a new pid, nor for a reused one whose counter restarted.
            if let last = previous[pid], now > last.uptime, cpu >= last.cpu {
                let percent = Double(cpu - last.cpu) / Double(now - last.uptime) * 100
                usageByPid[pid] = EngineUsage(
                    pid: pid, percent: percent, footprint: ProcessTaskInfoSampler.physicalFootprint(pid: pid) ?? 0
                )
            }
        }
        previous = next
        var result: [UUID: EngineUsage] = [:]
        for (tabId, pid) in pidByTab {
            if let usage = usageByPid[pid] { result[tabId] = usage }
        }
        return result
    }
}
