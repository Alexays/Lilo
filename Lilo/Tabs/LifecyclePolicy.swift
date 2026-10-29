import Foundation

/// User-facing tab-lifecycle aggressiveness preset. Raw values are the SettingsStore string keys.
enum LifecyclePreset: String, CaseIterable, Sendable {
    case conservative
    case balanced
    case aggressive

    static let `default`: LifecyclePreset = .balanced
}

/// All tab-lifecycle thresholds in one place, read by MainWindowController,
/// HiddenSpaceLifecycleController and TabLifecycleCoordinator. A preset maps to one of these.
struct LifecyclePolicyConfig: Sendable, Equatable {
    var maxNormalRetainedEnginesPerHiddenSpace: Int = 1
    var maxHiddenSpacesWithNormalRetainedEngines: Int
    var audioGracePeriod: TimeInterval = 30
    /// Grace after capture (mic/camera/screen) stops before its engine loses capture protection.
    /// Absorbs WebKit's transient `.none` blips during a live call. Mirrors `audioGracePeriod`.
    var captureGracePeriod: TimeInterval = 30
    var restorationGracePeriod: TimeInterval = 10
    var backgroundTrimGracePeriod: TimeInterval
    var constrainedForegroundEngineBudget: Int
    /// Idle (since lastActiveAt) before a background engine is frozen. `.infinity` disables freezing.
    var freezeThreshold: TimeInterval
    /// Idle before a background engine is discarded outright. `.infinity` = discard only under pressure.
    var discardThreshold: TimeInterval
    /// How often the idle sweep runs.
    var idleSweepInterval: TimeInterval
    /// Scales the RAM-adaptive foreground budget. 1.0 keeps it unscaled.
    var foregroundEngineBudgetMultiplier: Double
    /// Fraction of physical RAM the summed WebContent resident footprint may reach before the idle
    /// sweep trims extra engines, ahead of the OS memory-pressure signal. Conservative: WebContent is
    /// only one slice of the app (GPU, network, chrome, OS all need headroom), so 40% leaves room.
    static let memoryFootprintCeilingFraction = 0.40
    /// Floor for the footprint ceiling so a small-RAM machine still keeps a usable working set rather
    /// than trimming down to almost nothing.
    static let memoryFootprintCeilingFloorBytes: UInt64 = 1_500_000_000
    /// Share of one core a background engine's content process may hold on two consecutive idle
    /// sweeps before it is discarded, ahead of `discardThreshold`.
    static let busyEngineCPUPercent: Double = 30
    /// Sustained constrained power (Low Power Mode, serious thermal) required before it is adopted, absorbing thermal flapping on a loaded
    /// laptop; leaving constrained power applies immediately, since relaxing is safe.
    var constrainedPowerGracePeriod: TimeInterval = 30

    static let `default` = config(for: .default)

    /// Freezing is reversible and resumes instantly, so on battery every preset freezes early.
    static let batteryFreezeThreshold: TimeInterval = 60
    /// The sweep applies the thresholds, so it bounds how late past them a tab freezes.
    static let batteryIdleSweepInterval: TimeInterval = 30

    /// Battery tightens freezing only: a frozen tab already costs no energy, so discarding it earlier would only add reloads.
    static func config(for preset: LifecyclePreset, onBatteryPower: Bool = false) -> LifecyclePolicyConfig {
        var config = presetConfig(for: preset)
        guard onBatteryPower else { return config }
        config.freezeThreshold = min(config.freezeThreshold, batteryFreezeThreshold)
        config.idleSweepInterval = min(config.idleSweepInterval, batteryIdleSweepInterval)
        return config
    }

    private static func presetConfig(for preset: LifecyclePreset) -> LifecyclePolicyConfig {
        switch preset {
        case .balanced:
            return LifecyclePolicyConfig(
                maxNormalRetainedEnginesPerHiddenSpace: 6,
                maxHiddenSpacesWithNormalRetainedEngines: 2,
                backgroundTrimGracePeriod: 120,
                constrainedForegroundEngineBudget: 6,
                freezeThreshold: 300,
                discardThreshold: .infinity,
                idleSweepInterval: 60,
                foregroundEngineBudgetMultiplier: 1.0
            )
        case .conservative:
            return LifecyclePolicyConfig(
                maxNormalRetainedEnginesPerHiddenSpace: 12,
                maxHiddenSpacesWithNormalRetainedEngines: 3,
                backgroundTrimGracePeriod: 120,
                constrainedForegroundEngineBudget: 6,
                freezeThreshold: 900,
                discardThreshold: .infinity,
                idleSweepInterval: 120,
                foregroundEngineBudgetMultiplier: 1.0
            )
        case .aggressive:
            return LifecyclePolicyConfig(
                maxHiddenSpacesWithNormalRetainedEngines: 1,
                backgroundTrimGracePeriod: 60,
                constrainedForegroundEngineBudget: 4,
                freezeThreshold: 120,
                discardThreshold: 600,
                idleSweepInterval: 30,
                foregroundEngineBudgetMultiplier: 0.5
            )
        }
    }
}
