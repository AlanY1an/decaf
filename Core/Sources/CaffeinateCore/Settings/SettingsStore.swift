// SettingsStore — UserDefaults-backed settings, the single source of truth for
// preference keys (plan 04 §5). Runtime values for batteryThreshold / gracePeriod
// are injected from here into the engine and detection layer (review decision R3).
//
// Note on "8 settings" (plan 04 §5): the three MVP settings tabs list 8 items
// total, but only 5 are persisted preferences — "launch at login" reads
// SMAppService directly, the Claude Code row is probe-driven status display, and
// "Remove all integrations" is an action button. SettingsKey below is the
// complete persisted set per plan 04.

import Foundation

/// The UserDefaults keys (plan 04 §5 — the only place keys are defined).
public enum SettingsKey {
    /// Encoded `ManualMode` (JSON). Default: `.infinite`.
    public static let defaultManualMode = "defaultManualMode"
    /// "Until" time as minutes since midnight. Default 1080 (18:00).
    public static let untilTime = "untilTime"
    /// Battery gate threshold percent; 0 = off. Default 20.
    public static let batteryThreshold = "batteryThreshold"
    /// Agent release grace period in minutes. Default 3.
    public static let gracePeriodMinutes = "gracePeriodMinutes"
    /// Whether onboarding has completed. Default false.
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"
    /// `DisplayPolicy.rawValue` applied to new holds. Default "allowSleep".
    public static let defaultDisplayPolicy = "defaultDisplayPolicy"
    /// `AgentHoldMode.rawValue`. Default "whileWorking".
    public static let agentHoldMode = "agentHoldMode"
}

/// Typed access to Caffeinate's persisted settings.
public final class SettingsStore {
    /// Factory defaults (plan 04 §5).
    public enum Defaults {
        public static let defaultManualMode: ManualMode = .infinite
        public static let untilTimeMinutes = 1080 // 18:00
        public static let batteryThreshold = 20
        public static let gracePeriodMinutes = 3
        /// The behaviour most people never touch: keep working, let the screen
        /// sleep normally.
        public static let displayPolicy: DisplayPolicy = .allowSleep
        /// Hold only while an agent is WORKING. This default is the product —
        /// an agent left open at its prompt must not keep a Mac awake all
        /// night — and `.whileRunning` is strictly an opt-in for people who
        /// want the blunt instrument.
        public static let agentHoldMode: AgentHoldMode = .whileWorking
    }

    private let defaults: UserDefaults

    /// Pass a dedicated suite in tests; the app uses `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The manual mode applied by the left-click toggle / main switch.
    public var defaultManualMode: ManualMode {
        get {
            guard
                let data = defaults.data(forKey: SettingsKey.defaultManualMode),
                let mode = try? JSONDecoder().decode(ManualMode.self, from: data)
            else {
                return Defaults.defaultManualMode
            }
            return mode
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: SettingsKey.defaultManualMode)
        }
    }

    /// The "until HH:MM" menu item's time, in minutes since midnight.
    public var untilTimeMinutes: Int {
        get {
            defaults.object(forKey: SettingsKey.untilTime) as? Int
                ?? Defaults.untilTimeMinutes
        }
        set { defaults.set(newValue, forKey: SettingsKey.untilTime) }
    }

    /// Battery gate threshold percent; 0 means the battery gate is off.
    public var batteryThreshold: Int {
        get {
            defaults.object(forKey: SettingsKey.batteryThreshold) as? Int
                ?? Defaults.batteryThreshold
        }
        set { defaults.set(newValue, forKey: SettingsKey.batteryThreshold) }
    }

    /// Agent release grace period, in minutes (UI presets 1/2/3/5/10).
    public var gracePeriodMinutes: Int {
        get {
            defaults.object(forKey: SettingsKey.gracePeriodMinutes) as? Int
                ?? Defaults.gracePeriodMinutes
        }
        set { defaults.set(newValue, forKey: SettingsKey.gracePeriodMinutes) }
    }

    /// Display behaviour applied to every newly created hold: agent holds
    /// always use it, and a manual hold starts from it (the menu can then
    /// change the running manual hold, which also updates this default for the
    /// next one).
    public var defaultDisplayPolicy: DisplayPolicy {
        get {
            guard
                let raw = defaults.string(forKey: SettingsKey.defaultDisplayPolicy),
                let policy = DisplayPolicy(rawValue: raw)
            else {
                return Defaults.displayPolicy
            }
            return policy
        }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.defaultDisplayPolicy) }
    }

    /// When an agent keeps this Mac awake — while it WORKS (the default) or for
    /// as long as it is RUNNING at all.
    ///
    /// Read on every `CompositionRoot.applyTuning()`, not only at launch: a
    /// preference that reaches `init` and nothing else is a preference that
    /// does nothing in a menu bar app nobody ever quits (plan 02's ruling, and
    /// the exact shape of the grace-period defect fixed earlier today).
    ///
    /// An unrecognised stored value falls back to the factory default rather
    /// than trapping — `UserDefaults` is a file the user can edit, and a
    /// garbled string must not be able to talk the app into the costlier mode.
    public var agentHoldMode: AgentHoldMode {
        get {
            guard
                let raw = defaults.string(forKey: SettingsKey.agentHoldMode),
                let mode = AgentHoldMode(rawValue: raw)
            else {
                return Defaults.agentHoldMode
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.agentHoldMode) }
    }

    /// Whether first-run onboarding has been completed.
    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: SettingsKey.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: SettingsKey.hasCompletedOnboarding) }
    }
}
